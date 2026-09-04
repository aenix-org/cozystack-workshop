#!/usr/bin/env bash
# Prüfung für Lab 3: Autoscaling.
#
# Wir prüfen nicht, ob „hpa.yaml angewendet ist", sondern ob der Mechanismus lebt und Entscheidungen treffen kann:
#   - der Container hat requests.cpu, sonst gibt es nichts, wovon der Prozentsatz berechnet werden kann;
#   - der HPA existiert und zielt genau auf unser Deployment;
#   - der Bereich ist sinnvoll gesetzt (maxReplicas größer als eins, sonst gibt es keinen Platz zum Wachsen);
#   - Metriken werden WIRKLICH erfasst: im Status steht eine Zahl, nicht <unknown>;
#   - Skalierung hat bereits ausgelöst, das heißt, es wurde tatsächlich Last angelegt.
#
# Das Skript ändert nichts. Ein Einweg-Pod wird nur gestartet, um zu prüfen,
# dass Fortio von innerhalb des Clusters antwortet, und entfernt sich selbst.
#
# Läuft auf der VM, aus dem Ordner dieses Labs, mit Zugriff auf den Trainingscluster `lab`
# (nicht auf einen Tenant auf dem Management-Cluster):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/03-scale && ./check.sh
# Die Variable COZY_TENANT wird hier nicht benötigt: das gesamte Lab läuft innerhalb des Clusters `lab`.
#
# VOR dem Aufräumen ausführen. Ein Teil der Prüfungen stützt sich auf Spuren von bereits geschehenem Wachstum,
# und die leben zusammen mit dem HPA-Objekt: löschen Sie es — und es gibt nichts mehr zu beweisen.

# Kommen in den Berichtskopf und in den Dateinamen report-<lab>-<datum>.md neben dem Skript.
LAB_NAME="03-scale"
LAB_TITLE="Lab 3 · Last und Autoscaling"
# Gemeinsame Bibliothek: ok / fail / warn / evidence / finish, Abfragen von innerhalb des Clusters,
# Schreiben des Berichts. Der Pfad wird vom Ort des Skripts selbst aus berechnet, nicht vom aktuellen Verzeichnis.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Ohne KUBECONFIG sucht kubectl einen Cluster auf der VM und lässt alles mit einem einzigen Fehler scheitern,
# in dem die wahre Ursache nicht zu erkennen ist. Wir halten sofort an.
need_kubeconfig

# Namen sind in Variablen ausgelagert, damit die Übereinstimmung von Anwendungsname und HPA-Name
# in diesem Lab nicht wie derselbe, versehentlich zweimal geschriebene Name aussieht.
APP=rickroll
HPA=rickroll

# --- Skalierungsziel vorhanden ---------------------------------------------
# Die Anwendung aus Lab 1 — das, was der HPA verwaltet. Fehlt sie, würden alle weiteren
# Prüfungen kaskadenartig scheitern und der Teilnehmer bekäme ein Dutzend Fehler statt eines
# verständlichen, deshalb ist dies die einzige Stelle, an der das Skript vorzeitig beendet wird.
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "Anwendung ${APP} ist nicht im Cluster — es gibt nichts zu skalieren" \
       "stellen Sie sie bereit: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi
ok "Anwendung ${APP} ist vorhanden"

# --- requests.cpu: ohne ihn berechnet der HPA keine Prozentsätze -----------
# Die häufigste Ursache für „HPA funktioniert nicht", und am Manifest ist sie nicht zu sehen:
# das Objekt wird erfolgreich erstellt, aber TARGETS bleibt für immer <unknown>.
REQ_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)"
LIM_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null)"

if [ -n "$REQ_CPU" ]; then
  ok "der Container hat requests.cpu = ${REQ_CPU} gesetzt — es gibt etwas, wovon Prozentsätze berechnet werden können"
  evidence "Container-Ressourcen" "requests.cpu: ${REQ_CPU}
limits.cpu:   ${LIM_CPU:-nicht gesetzt}"
else
  fail "der Container ${APP} hat kein requests.cpu gesetzt" \
       "HPA nach Utilization funktioniert ohne ihn nicht; wenden Sie ../01-deploy/rickroll.yaml erneut an"
fi

# --- der HPA selbst --------------------------------------------------------
# Wir prüfen nicht nur, ob das Objekt existiert, sondern auch, worauf es zielt. Ein HPA mit einem Tippfehler
# in scaleTargetRef wird erfolgreich erstellt und sieht in der Liste wie ein funktionierender aus, aber das ganze Lab
# verwaltet er eine nicht existierende Anwendung.
TARGET_KIND="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.kind}' 2>/dev/null)"
TARGET_NAME="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)"

if [ -z "$TARGET_NAME" ]; then
  fail "es gibt keinen HorizontalPodAutoscaler mit dem Namen ${HPA} im Cluster" \
       "wenden Sie ihn an: kubectl apply -f hpa.yaml (Prüfung vor dem Aufräumen ausführen)"
  evidence "Was an Autoscaling vorhanden ist" "$(kubectl get hpa 2>&1)"
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
  fail "die obere Grenze des Bereichs ist ${MAXR:-nicht gesetzt} — es gibt keinen Platz zum Wachsen" \
       "in hpa.yaml muss maxReplicas größer als eins sein"
fi

# --- Metrikziel ------------------------------------------------------------
# Hier warn, nicht fail: die Variante mit AverageValue (Schwelle in Millicores) funktioniert ebenfalls,
# das Lab behandelt nur eine der beiden. Deswegen durchfallen zu lassen wäre unwahr.
TGT_TYPE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.type}' 2>/dev/null)"
TGT_VAL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null)"

if [ "$TGT_TYPE" = "Utilization" ] && [ -n "$TGT_VAL" ]; then
  ok "Schwelle ist gesetzt: ${TGT_VAL}% von requests.cpu (${REQ_CPU:-?})"
else
  warn "die Schwelle ist nicht als Prozentsatz von requests gesetzt (Typ: ${TGT_TYPE:-keiner})" \
       "das Lab behandelt die Variante Utilization; auf die Funktionsfähigkeit hat das keinen Einfluss"
fi

# --- DAS WICHTIGSTE: Metriken werden wirklich erfasst ----------------------
# Genau hier sieht man den Unterschied zwischen „Objekt erstellt" und „Mechanismus funktioniert".
CUR_UTIL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)"
SCALING_ACTIVE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.status}{end}' 2>/dev/null)"

if [ -n "$CUR_UTIL" ] && [ "$SCALING_ACTIVE" = "True" ]; then
  ok "Metriken werden erfasst: aktuelle Last ${CUR_UTIL}% von requests, HPA trifft Entscheidungen"
elif [ "$SCALING_ACTIVE" = "True" ]; then
  ok "HPA trifft Entscheidungen (ScalingActive=True), der aktuelle Metrikwert wurde noch nicht geliefert"
else
  REASON="$(kubectl get hpa "$HPA" \
    -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.reason}: {.message}{end}' 2>/dev/null)"
  fail "HPA erhält keine Metriken — in TARGETS wird <unknown> stehen, er hat nichts, worüber er entscheiden kann" \
       "die ersten zwei Minuten nach apply ist das normal, warten Sie und wiederholen Sie; wenn es nicht verging — kubectl top pods und kubectl describe hpa ${HPA}"
  evidence "Warum der HPA nicht aktiv ist" "${REASON:-Ursache im Status nicht angegeben}"
fi

evidence "Zustand des HPA" "$(kubectl get hpa "$HPA" 2>/dev/null)"

# --- metrics-server antwortet direkt ---------------------------------------
# Dupliziert die vorherige Prüfung von der anderen Seite und trennt zwei verschiedene Störungen:
# „keine Metriken im ganzen Cluster" und „Metriken sind da, aber der HPA hat sie nicht erreicht".
# Erstes behebt der Cluster-Administrator, zweites der Teilnehmer in seinem Manifest.
TOP="$(kubectl top pods -l app=${APP} --no-headers 2>&1)"
# `kubectl top` gibt bei fehlenden Pods „No resources found" aus und liefert 0 zurück —
# ohne eine explizite Leerheitsprüfung gab das ein Grün dort, wo es überhaupt keine Metriken gibt.
if [ -z "$TOP" ] || printf '%s' "$TOP" | grep -qiE 'error|not available|No resources found'; then
  fail "kubectl top liefert keinen Podverbrauch" \
       "im Cluster gibt es keinen funktionierenden metrics-server — ohne ihn ist CPU-basiertes Autoscaling unmöglich"
  evidence "Antwort von kubectl top" "$TOP"
else
  ok "metrics-server liefert den Verbrauch der ${APP}-Pods"
  evidence "Verbrauch der Kopien" "$TOP"
fi

# --- Skalierung hat tatsächlich ausgelöst ----------------------------------
# lastScaleTime lebt so lange wie der HPA selbst, deshalb hängt die Prüfung nicht davon ab,
# ob die Cluster-Events abgelaufen sind oder nicht.
LAST_SCALE="$(kubectl get hpa "$HPA" -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
CUR_REPL="$(kubectl get hpa "$HPA" -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"

# Ein einzelner Zeitstempel reicht nicht: er wird auch beim Verringern der Kopien gesetzt, das heißt,
# er erscheint sogar bei jemandem, der die Replikas von Hand hochgesetzt und den HPA die überflüssigen entfernen ließ. Wir suchen
# genau das Wachstum DURCH LAST — ein Event mit überschrittener Schwelle.
#
# Und umgekehrt: der Zeitstempel selbst überlebt nicht immer. Auf einem Cluster, wo die Last vor einer Stunde
# angelegt wurde, kann lastScaleTime leer sein, während die Events noch leben — deshalb werden die Events
# ZUERST geprüft, sonst fällt ein erledigtes Lab fälschlich durch.
SCALE_UP="$(kubectl get events --field-selector involvedObject.name="$HPA" \
  -o jsonpath='{range .items[*]}{.reason}{" "}{.message}{"\n"}{end}' 2>/dev/null \
  | grep -i 'SuccessfulRescale' | grep -ci 'above target')"

if [ "${SCALE_UP:-0}" -ge 1 ]; then
  ok "HPA hat die Anzahl der Kopien wegen Last erhöht — das Event mit überschrittener Schwelle ist vorhanden"
  evidence "Skalierung" "Wachstums-Events: ${SCALE_UP}
lastScaleTime: ${LAST_SCALE:-keiner}
currentReplicas: ${CUR_REPL:-unbekannt}"
elif [ -n "$LAST_SCALE" ]; then
  ok "HPA hat die Anzahl der Kopien geändert (zuletzt: ${LAST_SCALE})"
  evidence "Skalierungs-Zeitstempel" "lastScaleTime: ${LAST_SCALE}
currentReplicas: ${CUR_REPL:-unbekannt}"
else
  fail "es gibt keine Spuren von Autoscaling-Aktivität" \
       "geben Sie Last aus Fortio: URL http://${APP}/, QPS 1200, Connections 80, Duration 90s"
fi

# --- Fortio: wird in Lab 4 benötigt ----------------------------------------
# Zum Lab 3 selbst hat es keinen Bezug mehr, deshalb warn, nicht fail. Der Sinn ist, dass der
# Teilnehmer vom fehlenden Generator hier erfährt, nicht mitten im Rollout unter Last,
# wenn Anhalten und Bereitstellen ungelegen käme.
if kubectl get deployment fortio >/dev/null 2>&1; then
  FBODY="$(in_cluster_curl "http://fortio:8080/fortio/")"
  if printf '%s' "$FBODY" | grep -qi 'fortio'; then
    ok "der Fortio-Lastgenerator funktioniert und antwortet von innerhalb des Clusters"
  else
    warn "Fortio ist bereitgestellt, aber seine Weboberfläche hat nicht geantwortet" \
         "prüfen Sie: kubectl rollout status deployment/fortio und kubectl logs deploy/fortio"
  fi
else
  warn "Fortio ist nicht im Cluster" \
       "wenn Sie Lab 4 machen wollen, wird es dort benötigt: kubectl apply -f fortio.yaml"
fi

finish
