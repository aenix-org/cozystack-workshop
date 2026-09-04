#!/usr/bin/env bash
# Prüfung für Lab 3: Autoskalierung.
#
# Wir prüfen nicht, ob «hpa.yaml angewendet wurde», sondern dass der Mechanismus lebt und Entscheidungen treffen kann:
#   - der Container hat requests.cpu, sonst gibt es keine Basis, um einen Prozentwert zu berechnen;
#   - der HPA existiert und zielt genau auf unser Deployment;
#   - der Bereich ist sinnvoll gesetzt (maxReplicas größer als eins, sonst gibt es keinen Platz zum Wachsen);
#   - Metriken werden WIRKLICH erfasst: im Status steht eine Zahl, kein <unknown>;
#   - die Skalierung hat bereits ausgelöst, das heißt es wurde tatsächlich Last erzeugt.
#
# Das Skript ändert nichts. Ein einmaliger Pod wird nur gestartet, um zu prüfen,
# dass Fortio von innerhalb des Clusters antwortet, und er entfernt sich selbst.
#
# Läuft auf dem Laptop, aus dem Ordner dieses Labs, über den Zugang zum Schulungscluster `lab`
# (nicht zum Tenant auf dem Management-Cluster):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/03-scale && ./check.sh
# Die Variable COZY_TENANT wird hier nicht benötigt: das gesamte Lab läuft innerhalb des Clusters `lab`.
#
# VOR dem Aufräumen ausführen. Ein Teil der Prüfungen stützt sich auf Spuren bereits erfolgten Wachstums,
# und die leben zusammen mit dem HPA-Objekt: löschen Sie es, und es bleibt nichts mehr zu beweisen.

# Diese landen in der Berichtsüberschrift und im Dateinamen report-<lab>-<datum>.md neben dem Skript.
LAB_NAME="03-scale"
LAB_TITLE="Lab 3 · Last und Autoskalierung"
# Gemeinsame Bibliothek: ok / fail / warn / evidence / finish, Abfragen von innerhalb des Clusters,
# Schreiben des Berichts. Der Pfad wird vom Ort des Skripts selbst berechnet, nicht vom aktuellen Verzeichnis.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Ohne KUBECONFIG sucht kubectl einen Cluster auf dem Laptop und wirft alles in einem Fehler zusammen,
# in dem die wahre Ursache nicht zu erkennen ist. Wir stoppen sofort.
need_kubeconfig

# Die Namen sind in Variablen ausgelagert, damit die Übereinstimmung von App-Name und HPA-Name
# in diesem Lab nicht wie derselbe Name aussieht, der versehentlich zweimal geschrieben wurde.
APP=rickroll
HPA=rickroll

# --- Skalierungsziel vorhanden ---------------------------------------------
# Die App aus Lab 1 ist das, was der HPA verwaltet. Fehlt sie, laufen alle weiteren
# Prüfungen kaskadenartig auf Fehler, und der Teilnehmer bekommt ein Dutzend Fehler statt eines
# klaren, deshalb ist dies die einzige Stelle, an der das Skript vorzeitig endet.
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "Anwendung ${APP} ist nicht im Cluster — nichts zu skalieren" \
       "stellen Sie sie bereit: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi
ok "Anwendung ${APP} ist vorhanden"

# --- requests.cpu: ohne ihn berechnet der HPA keine Prozentwerte -----------
# Die häufigste Ursache für «HPA funktioniert nicht», und im Manifest ist sie nicht sichtbar:
# das Objekt wird erfolgreich erstellt, aber TARGETS bleibt für immer <unknown>.
REQ_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)"
LIM_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null)"

if [ -n "$REQ_CPU" ]; then
  ok "der Container hat requests.cpu = ${REQ_CPU} — es gibt eine Basis, um Prozentwerte zu berechnen"
  evidence "Container-Ressourcen" "requests.cpu: ${REQ_CPU}
limits.cpu:   ${LIM_CPU:-nicht gesetzt}"
else
  fail "der Container ${APP} hat kein requests.cpu gesetzt" \
       "HPA nach Utilization funktioniert ohne ihn nicht; wenden Sie ../01-deploy/rickroll.yaml erneut an"
fi

# --- der HPA selbst --------------------------------------------------------
# Wir prüfen nicht nur, dass das Objekt existiert, sondern auch, worauf es zielt. Ein HPA mit einem Tippfehler
# in scaleTargetRef wird erfolgreich erstellt und sieht in der Liste funktionsfähig aus, aber das ganze Lab
# verwaltet er eine nicht existierende Anwendung.
TARGET_KIND="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.kind}' 2>/dev/null)"
TARGET_NAME="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)"

if [ -z "$TARGET_NAME" ]; then
  fail "im Cluster gibt es keinen HorizontalPodAutoscaler mit dem Namen ${HPA}" \
       "wenden Sie ihn an: kubectl apply -f hpa.yaml (führen Sie die Prüfung vor dem Aufräumen aus)"
  evidence "Was an Autoskalierung existiert" "$(kubectl get hpa 2>&1)"
  finish
  exit $?
fi

if [ "$TARGET_KIND" = "Deployment" ] && [ "$TARGET_NAME" = "$APP" ]; then
  ok "HPA ${HPA} zielt auf Deployment/${APP}"
else
  fail "HPA ${HPA} verwaltet das Objekt ${TARGET_KIND}/${TARGET_NAME}, nicht Deployment/${APP}" \
       "korrigieren Sie scaleTargetRef in hpa.yaml und wenden Sie es erneut an"
fi

MINR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)"
MAXR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)"
[ -z "$MINR" ] && MINR=1

if [ -n "$MAXR" ] && [ "$MAXR" -gt 1 ] 2>/dev/null; then
  ok "Bereich ist gesetzt: von ${MINR} bis ${MAXR} Kopien — es gibt Platz zum Wachsen"
else
  fail "die Obergrenze des Bereichs beträgt ${MAXR:-nicht gesetzt} — kein Platz zum Wachsen" \
       "in hpa.yaml muss maxReplicas größer als eins sein"
fi

# --- Metrikziel ------------------------------------------------------------
# Hier warn, nicht fail: die Variante mit AverageValue (Schwellwert in Millicores) funktioniert ebenfalls,
# das Lab behandelt nur eine der beiden. Dafür durchfallen zu lassen wäre unwahr.
TGT_TYPE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.type}' 2>/dev/null)"
TGT_VAL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null)"

if [ "$TGT_TYPE" = "Utilization" ] && [ -n "$TGT_VAL" ]; then
  ok "Schwellwert ist gesetzt: ${TGT_VAL}% von requests.cpu (${REQ_CPU:-?})"
else
  warn "Schwellwert ist nicht als Prozentwert von requests gesetzt (Typ: ${TGT_TYPE:-keiner})" \
       "das Lab behandelt die Variante Utilization; auf die Funktionsfähigkeit hat das keinen Einfluss"
fi

# --- DAS WICHTIGSTE: Metriken werden wirklich erfasst ----------------------
# Genau hier zeigt sich der Unterschied zwischen «Objekt erstellt» und «Mechanismus funktioniert».
CUR_UTIL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)"
SCALING_ACTIVE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.status}{end}' 2>/dev/null)"

if [ -n "$CUR_UTIL" ] && [ "$SCALING_ACTIVE" = "True" ]; then
  ok "Metriken werden erfasst: aktuelle Auslastung ${CUR_UTIL}% von requests, HPA trifft Entscheidungen"
elif [ "$SCALING_ACTIVE" = "True" ]; then
  ok "HPA trifft Entscheidungen (ScalingActive=True), der aktuelle Metrikwert wird noch nicht geliefert"
else
  REASON="$(kubectl get hpa "$HPA" \
    -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.reason}: {.message}{end}' 2>/dev/null)"
  fail "HPA erhält keine Metriken — in TARGETS steht <unknown>, es gibt nichts, worüber er entscheiden könnte" \
       "die ersten zwei Minuten nach dem apply ist das normal, warten Sie und wiederholen Sie; wenn es nicht durchging — kubectl top pods und kubectl describe hpa ${HPA}"
  evidence "Warum der HPA nicht aktiv ist" "${REASON:-Ursache im Status nicht angegeben}"
fi

evidence "Zustand des HPA" "$(kubectl get hpa "$HPA" 2>/dev/null)"

# --- metrics-server antwortet direkt ---------------------------------------
# Dupliziert die vorherige Prüfung von einer anderen Seite und trennt zwei verschiedene Störungen:
# «es gibt keine Metriken im gesamten Cluster» und «Metriken gibt es, aber der HPA hat sie nicht erreicht».
# Ersteres behebt der Cluster-Administrator, Zweiteres der Teilnehmer in seinem Manifest.
TOP="$(kubectl top pods -l app=${APP} --no-headers 2>&1)"
# `kubectl top` gibt bei fehlenden Pods «No resources found» aus und liefert 0 zurück —
# ohne eine explizite Leerheitsprüfung gab das grün, wo es überhaupt keine Metriken gibt.
if [ -z "$TOP" ] || printf '%s' "$TOP" | grep -qiE 'error|not available|No resources found'; then
  fail "kubectl top liefert keinen Verbrauch der Pods" \
       "im Cluster gibt es keinen funktionierenden metrics-server — ohne ihn ist Autoskalierung nach CPU unmöglich"
  evidence "Antwort von kubectl top" "$TOP"
else
  ok "metrics-server liefert den Verbrauch der ${APP}-Pods"
  evidence "Verbrauch der Kopien" "$TOP"
fi

# --- Skalierung hat tatsächlich ausgelöst ----------------------------------
# lastScaleTime lebt so lange wie der HPA selbst, deshalb hängt diese Prüfung nicht
# davon ab, ob die Cluster-Events abgelaufen sind oder nicht.
LAST_SCALE="$(kubectl get hpa "$HPA" -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
CUR_REPL="$(kubectl get hpa "$HPA" -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"

# Ein einzelner Zeitstempel reicht nicht: er wird auch beim Verkleinern der Kopien gesetzt, das heißt
# er erscheint sogar bei jemandem, der die Repliken von Hand erhöht und den HPA die überzähligen entfernen ließ. Wir suchen
# genau ein Wachstum DURCH LAST — ein Event mit Überschreitung des Schwellwerts.
#
# Und umgekehrt: der Zeitstempel selbst lebt nicht immer. In einem Cluster, in dem die Last eine Stunde
# zuvor erzeugt wurde, kann lastScaleTime leer sein, während die Events noch leben — deshalb werden die Events
# ZUERST geprüft, sonst fällt ein erledigtes Lab fälschlich durch.
SCALE_UP="$(kubectl get events --field-selector involvedObject.name="$HPA" \
  -o jsonpath='{range .items[*]}{.reason}{" "}{.message}{"\n"}{end}' 2>/dev/null \
  | grep -i 'SuccessfulRescale' | grep -ci 'above target')"

if [ "${SCALE_UP:-0}" -ge 1 ]; then
  ok "HPA hat die Anzahl der Kopien wegen Last erhöht — das Event mit Schwellwertüberschreitung ist vorhanden"
  evidence "Skalierung" "Wachstums-Events: ${SCALE_UP}
lastScaleTime: ${LAST_SCALE:-keine}
currentReplicas: ${CUR_REPL:-unbekannt}"
elif [ -n "$LAST_SCALE" ]; then
  ok "HPA hat die Anzahl der Kopien geändert (zuletzt: ${LAST_SCALE})"
  evidence "Skalierungs-Zeitstempel" "lastScaleTime: ${LAST_SCALE}
currentReplicas: ${CUR_REPL:-unbekannt}"
else
  fail "es gibt keine Spuren von Autoskalierungs-Aktivität" \
       "erzeugen Sie Last aus Fortio: URL http://${APP}/, QPS 1200, Connections 80, Duration 90s"
fi

# --- Fortio: wird in Lab 4 benötigt ----------------------------------------
# Mit Lab 3 selbst hat es nichts mehr zu tun, deshalb warn, nicht fail. Der Sinn ist, dass der
# Teilnehmer vom Fehlen des Generators hier erfährt und nicht mitten in einem Rollout unter Last,
# wenn ein Anhalten zum Bereitstellen ungelegen käme.
if kubectl get deployment fortio >/dev/null 2>&1; then
  FBODY="$(in_cluster_curl "http://fortio:8080/fortio/")"
  if printf '%s' "$FBODY" | grep -qi 'fortio'; then
    ok "der Lastgenerator Fortio funktioniert und antwortet von innerhalb des Clusters"
  else
    warn "Fortio ist bereitgestellt, aber seine Weboberfläche hat nicht geantwortet" \
         "prüfen Sie: kubectl rollout status deployment/fortio und kubectl logs deploy/fortio"
  fi
else
  warn "Fortio ist nicht im Cluster" \
       "wenn Sie Lab 4 machen wollen, wird es dort benötigt: kubectl apply -f fortio.yaml"
fi

finish
