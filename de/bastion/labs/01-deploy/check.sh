#!/usr/bin/env bash
# Prüfung für Lab 1: Die Anwendung ist deployt und funktioniert im Kern.
#
# «Im Kern» bedeutet hier: Die Seite wird tatsächlich über HTTP ausgeliefert, der
# Pod-Name ist in sie eingesetzt, und dieser Name stimmt mit dem Namen einer wirklich
# laufenden Replik überein. Zu prüfen, ob ein Deployment-Objekt existiert, ist sinnlos —
# es kann existieren und trotzdem nicht funktionieren.
#
# Läuft auf der VM, aus dem Ordner dieses Labs, über den Zugang zum Schulungscluster `lab`
# (nicht zum Tenant auf dem Management-Cluster):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/01-deploy && ./check.sh
# Die Variable COZY_TENANT wird hier nicht benötigt: Das gesamte Lab läuft innerhalb des Clusters `lab`.
#
# Das Skript ändert nichts im Cluster — es liest nur und sendet HTTP-Anfragen.
# Führe es vor dem Aufräumen aus: Nach dem Löschen der Anwendung gibt es nichts mehr zu prüfen.

# Diese beiden Variablen werden von lib.sh aufgegriffen — sie landen im Kopf des Berichts und im
# Dateinamen report-<lab>-<datum>.md, den das Skript neben sich ablegt.
LAB_NAME="01-deploy"
LAB_TITLE="Lab 1 · Erste Anwendung"
# Die gemeinsame Prüf-Bibliothek: Von hier kommen ok / fail / warn / evidence / finish,
# die Seitenanfrage von innerhalb des Clusters und das Schreiben des Berichts. Der Pfad wird von dem Ort
# aus berechnet, an dem das Skript selbst liegt, daher funktioniert der Start aus jedem Verzeichnis gleich.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Sofort anhalten, wenn KUBECONFIG nicht gesetzt ist. Ohne sie sucht kubectl einen Cluster
# auf der VM selbst, findet keinen und lässt jede Prüfung nacheinander mit demselben Fehler scheitern,
# aus dem die wahre Ursache nicht ersichtlich ist.
need_kubeconfig

# --- Anwendungsobjekt -------------------------------------------------------
# Erste Verteidigungslinie: Die Anwendung ist tatsächlich eingerichtet und mindestens eine Replik hat die Bereitschaft erreicht.
# Wir schauen auf .status.readyReplicas, nicht auf die bloße Existenz des Deployments: Das Objekt
# wird sofort und immer erfolgreich erstellt, wohingegen Bereitschaft bedeutet, dass eine Replik hochgekommen ist,
# ihre Readiness-Probe bestanden hat und in der Lage ist zu antworten.
if kubectl get deployment rickroll >/dev/null 2>&1; then
  DESIRED="$(kubectl get deployment rickroll -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  READY="$(kubectl get deployment rickroll -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  READY="${READY:-0}"
  DESIRED="${DESIRED:-0}"
  if [ "$DESIRED" -eq 0 ]; then
    # Sonderfall: Das Objekt existiert, aber es sind null Repliken für es angefordert. Die Meldung
    # «keine Replik ist bereit (0 benötigt)» würde wie Unsinn klingen.
    fail "Anwendung gestoppt — 0 Repliken angefordert" \
         "eine Replik zurückbringen: kubectl scale deployment rickroll --replicas=1"
  elif [ "$READY" -ge 1 ]; then
    ok "Anwendung deployt, ${READY} von ${DESIRED} Repliken bereit"
    # Ein festhängender Rollout legt den Dienst nicht lahm: Die alte Replik arbeitet weiter, und
    # readyReplicas bleibt bei eins. Ohne diese Prüfung geht der Teilnehmer mit einem grünen
    # Häkchen und einem Deployment davon, das für immer in ErrImagePull festhängt.
    # Wir schauen auf die Repliken selbst, nicht nur auf ProgressDeadlineExceeded: Die Frist
    # greift nach zehn Minuten, während das Skript sofort ausgeführt wird. Die alte Replik arbeitet
    # dabei weiter, readyReplicas bleibt bei eins, und ohne diese Prüfung geht der Teilnehmer
    # mit einem grünen Häkchen und einem in ImagePullBackOff festhängenden Deployment davon.
    STUCK="$(kubectl get pods -l app=rickroll \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
      | awk '$2=="ImagePullBackOff" || $2=="ErrImagePull" || $2=="CrashLoopBackOff" || $2=="CreateContainerConfigError" {print $1" ("$2")"}')"
    PROG_REASON="$(kubectl get deployment rickroll \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null)"
    if [ -n "$STUCK" ] || [ "$PROG_REASON" = "ProgressDeadlineExceeded" ]; then
      fail "Rollout hängt fest: Die neue Replik kommt nicht hoch, nur die alte arbeitet" \
           "schau in kubectl get pods -l app=rickroll — meist wurde das Image nicht gezogen; funktionierenden Zustand wiederherstellen: kubectl apply -f rickroll.yaml"
      evidence "Repliken, die nicht starten" "${STUCK:-Ursache im Deployment-Status: $PROG_REASON}"
    fi
  else
    fail "Anwendung erstellt, aber keine Replik ist bereit (${DESIRED} benötigt)" \
         "schau in kubectl get pods -l app=rickroll und kubectl describe deployment rickroll"
    evidence "Pod-Zustand" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
  fi
else
  fail "kein Deployment mit dem Namen rickroll gefunden" \
       "wende das Manifest an: kubectl apply -f rickroll.yaml"
fi

# --- Einstellungen und Seite ------------------------------------------------
# Beide ConfigMaps werden von derselben Datei wie die Anwendung erstellt, daher können sie nur
# zusammen mit ihr oder durch manuelles Löschen verschwinden. Wir prüfen sie separat, damit bei
# einem Defekt der Seite der Teilnehmer sofort sieht, was genau fehlt: ohne rickroll-conf
# setzt nginx den Pod-Namen nicht ein, und ohne rickroll-page-v1 gibt es in Lab 4 nichts, womit
# die zweite Version verglichen werden kann, und nichts, wohin zurückgerollt werden kann.
for cm in rickroll-conf rickroll-page-v1; do
  if kubectl get configmap "$cm" >/dev/null 2>&1; then
    ok "Einstellungen vorhanden: ConfigMap ${cm}"
  else
    fail "ConfigMap ${cm} nicht gefunden" \
         "sie wird von derselben Datei erstellt: kubectl apply -f rickroll.yaml"
  fi
done

# --- feste Adresse ----------------------------------------------------------
if kubectl get service rickroll >/dev/null 2>&1; then
  # Ein Service ohne Endpoints ist ein typischer und unauffälliger Defekt: Das Objekt existiert,
  # aber die Labels an den Pods haben nicht zum Selektor gepasst, und hinter der Adresse ist es leer.
  EPS="$(kubectl get endpoints rickroll -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
  EPS_N="$(printf '%s' "$EPS" | wc -w | tr -d ' ')"
  if [ "${EPS_N:-0}" -ge 1 ]; then
    ok "feste Adresse funktioniert, Repliken dahinter: ${EPS_N}"
    evidence "Adressen hinter dem Service" "$EPS"
  else
    fail "Service rickroll existiert, aber es steht keine Replik dahinter" \
         "meist liegt die Ursache darin, dass die Pod-Labels nicht zum Service-Selektor gepasst haben — prüfe app: rickroll"
  fi
else
  fail "kein Service mit dem Namen rickroll gefunden" \
       "er wird von derselben Datei erstellt: kubectl apply -f rickroll.yaml"
fi

# --- die Hauptsache: die Seite wird tatsächlich ausgeliefert -----------------
# Für diese Prüfung war alles gedacht. Alle vorherigen sagen nur, dass die Objekte
# im Cluster korrekt beschrieben sind; diese — dass der Nutzer die Seite bekommt. Die Anfrage geht
# VON INNERHALB des Clusters, mit einem Einweg-Pod: Von außen existiert die Adresse rickroll nicht, und
# port-forward würde hier deine VM prüfen, nicht den Cluster.
# Wir fragen mehrmals an: Bei mehreren Repliken hinter dem Service kann eine einzelne Stichprobe
# die ausgetauschte verfehlen, und die Prüfung wird grün auf fremdem Inhalt.
BODY="$(in_cluster_curl_many 'http://rickroll/' 8)"
# Der Marker muss GENAU EINMAL pro Seite vorkommen, sonst lügt der Antwortzähler:
# «Never Gonna Give You Up» steht sowohl in <title> als auch in <h1> und ergab eine Verdopplung.
ANSWERS="$(printf '%s' "$BODY" | grep -c 'вас обслужил под')"
TOTAL_LINES="$(printf '%s' "$BODY" | grep -c '<title>')"
if [ "${ANSWERS:-0}" -ge 1 ] && [ "${ANSWERS:-0}" -eq "${TOTAL_LINES:-0}" ]; then
  ok "Anwendung antwortet über HTTP und liefert ihre Seite aus (${ANSWERS} Anfragen geprüft)"
elif [ "${ANSWERS:-0}" -ge 1 ]; then
  fail "hinter dem Service antwortet nicht nur deine Anwendung: deine Seite kam ${ANSWERS} von ${TOTAL_LINES} Mal zurück" \
       "jemand anderes trägt das Label app=rickroll — schau in kubectl get pods -l app=rickroll und entferne das Überflüssige"
else
  fail "die Anwendung hat die erwartete Seite nicht ausgeliefert" \
       "prüfe manuell: kubectl port-forward svc/rickroll 8080:80, dann öffne http://localhost:8080"
  evidence "Was statt der Seite zurückkam" "$(printf '%s' "$BODY" | head -20)"
fi

# --- Einsetzen des Pod-Namens -----------------------------------------------
# Dafür wurde das Lab gemacht: Der Name auf der Seite muss mit dem echten Pod übereinstimmen.
SERVED_BY="$(printf '%s' "$BODY" | grep -o '<b>[^<]*</b>' | head -1 | sed 's/<[^>]*>//g')"
# Wir nehmen die Pods, die vom ReplicaSet der Anwendung verwaltet werden, und NICHT alles, was das
# Label app=rickroll trägt. Sonst landet ein fremder Pod mit einem solchen Label in der Liste der «echten»
# und bestätigt sich selbst — geprüft, ein Hochstapler hat die Prüfung auf diese Weise bestanden.
REAL_PODS="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
STRAY="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | awk '$2!="ReplicaSet" {print $1}')"
if [ -n "$STRAY" ]; then
  fail "fremde Pods tragen das Label app=rickroll — sie werden in die Lastverteilung einbezogen" \
       "entferne das Überflüssige: $(printf '%s' "$STRAY" | tr '\n' ' ')"
  evidence "Fremde Pods unter dem Label der Anwendung" "$STRAY"
fi

if [ -z "$SERVED_BY" ]; then
  fail "auf der Seite steht kein Pod-Name" \
       "prüfe, dass die ConfigMap rickroll-conf eingesetzt wurde — in ihr steht die Zeile sub_filter '__POD__' '\$hostname'"
elif [ "$SERVED_BY" = "__POD__" ]; then
  fail "der Pod-Name wurde nicht eingesetzt — auf der Seite ist der Platzhalter __POD__ geblieben" \
       "nginx hat sub_filter nicht angewendet: prüfe, dass das Einstellungs-Volume unter /etc/nginx/conf.d gemountet ist"
elif printf '%s' "$REAL_PODS" | grep -qx "$SERVED_BY"; then
  ok "der Pod-Name wird eingesetzt und stimmt mit einer wirklich laufenden Replik überein: ${SERVED_BY}"
  evidence "Wer die Anfrage bedient hat" "$SERVED_BY"
  evidence "Laufende Repliken" "$REAL_PODS"
else
  fail "die Seite nennt den Pod «${SERVED_BY}», aber es gibt keinen solchen Pod im Cluster" \
       "möglicherweise wurde die Replik zwischen Anfrage und Prüfung neu erstellt — führe das Skript noch einmal aus"
fi

# --- Readiness-Probe ist konfiguriert ---------------------------------------
# Ohne sie wird es im Lab über den Versions-Rollout Ausfallzeit geben, und der Teilnehmer wird meinen, wir hätten gelogen.
PROBE_PATH="$(kubectl get deployment rickroll \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE_PATH" ]; then
  ok "Readiness-Probe ist konfiguriert (${PROBE_PATH}) — das Update läuft ohne Ausfallzeit durch"
else
  warn "die Anwendung hat keine Readiness-Probe" \
       "Lab 4 über Updates ohne Ausfallzeit wird bei einer solchen Anwendung Fehler erzeugen — stelle readinessProbe aus rickroll.yaml wieder her"
fi

finish
