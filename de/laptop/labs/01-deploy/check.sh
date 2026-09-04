#!/usr/bin/env bash
# Prüfung für Lab 1: Die Anwendung ist deployt und funktioniert im Kern wirklich.
#
# „Im Kern" heißt hier: Die Seite wird tatsächlich über HTTP ausgeliefert, ein Pod-Name
# ist darin eingesetzt, und dieser Name stimmt mit dem Namen einer wirklich laufenden
# Kopie überein. Zu prüfen, ob ein Deployment-Objekt existiert, ist sinnlos — es kann
# existieren und trotzdem nicht funktionieren.
#
# Läuft auf dem Laptop, aus dem Ordner dieses Labs, über den Zugang zum Trainings-Cluster
# `lab` (nicht zu einem Tenant auf dem Management-Cluster):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/01-deploy && ./check.sh
# Die Variable COZY_TENANT wird hier nicht gebraucht: Das ganze Lab läuft innerhalb des Clusters `lab`.
#
# Das Skript verändert nichts im Cluster — es liest nur und sendet HTTP-Anfragen.
# Vor dem Aufräumen ausführen: Nach dem Löschen der Anwendung gibt es nichts mehr zu prüfen.

# Diese beiden Variablen greift lib.sh auf — sie landen im Kopf des Berichts und im
# Dateinamen report-<lab>-<datum>.md, den das Skript neben sich ablegt.
LAB_NAME="01-deploy"
LAB_TITLE="Lab 1 · Deine erste Anwendung"
# Gemeinsame Prüfbibliothek: von hier kommen ok / fail / warn / evidence / finish,
# die Seitenanfrage von innerhalb des Clusters und das Schreiben des Berichts. Der Pfad
# wird relativ zum Ort des Skripts berechnet, daher funktioniert der Start aus jedem Verzeichnis gleich.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Wir stoppen sofort, wenn KUBECONFIG nicht gesetzt ist. Ohne sie sucht kubectl einen Cluster
# auf dem Laptop selbst, findet keinen und wirft eine Prüfung nach der anderen mit demselben
# Fehler um, der die wahre Ursache verdeckt.
need_kubeconfig

# --- Anwendungsobjekt ------------------------------------------------------
# Erste Linie: Die Anwendung existiert überhaupt und mindestens eine Kopie hat Bereitschaft erreicht.
# Wir schauen auf .status.readyReplicas, nicht auf die Tatsache, dass das Deployment existiert: Das Objekt
# wird sofort erzeugt und gelingt immer, Bereitschaft dagegen bedeutet, dass eine Kopie hochgekommen ist,
# ihre Bereitschaftsprüfung bestanden hat und antworten kann.
if kubectl get deployment rickroll >/dev/null 2>&1; then
  DESIRED="$(kubectl get deployment rickroll -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  READY="$(kubectl get deployment rickroll -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  READY="${READY:-0}"
  DESIRED="${DESIRED:-0}"
  if [ "$DESIRED" -eq 0 ]; then
    # Sonderfall: Das Objekt existiert, aber es sind null Kopien angefordert. Eine Meldung
    # „keine Kopie ist bereit (0 benötigt)" würde wie Unsinn klingen.
    fail "Anwendung gestoppt — 0 Kopien angefordert" \
         "eine Kopie zurückholen: kubectl scale deployment rickroll --replicas=1"
  elif [ "$READY" -ge 1 ]; then
    ok "Anwendung deployt, bereite Kopien ${READY} von ${DESIRED}"
    # Ein hängengebliebener Rollout legt den Dienst nicht lahm: Die alte Kopie arbeitet weiter, und
    # readyReplicas bleibt bei eins. Ohne diese Prüfung geht der Teilnehmer mit einem grünen
    # Haken und einem Deployment weg, das für immer in ErrImagePull steckt.
    # Wir schauen auf die Kopien selbst, nicht nur auf ProgressDeadlineExceeded: Die Frist
    # greift nach zehn Minuten, das Skript wird aber sofort gestartet. Die alte Kopie arbeitet
    # derweil, readyReplicas bleibt bei eins, und ohne diese Prüfung geht der Teilnehmer mit einem
    # grünen Haken und einem Deployment weg, das in ImagePullBackOff steckt.
    STUCK="$(kubectl get pods -l app=rickroll \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
      | awk '$2=="ImagePullBackOff" || $2=="ErrImagePull" || $2=="CrashLoopBackOff" || $2=="CreateContainerConfigError" {print $1" ("$2")"}')"
    PROG_REASON="$(kubectl get deployment rickroll \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null)"
    if [ -n "$STUCK" ] || [ "$PROG_REASON" = "ProgressDeadlineExceeded" ]; then
      fail "Rollout hängt: Die neue Kopie kommt nicht hoch, es arbeitet nur die alte" \
           "siehe kubectl get pods -l app=rickroll — meist wurde das Image nicht gezogen; funktionierenden Zustand wiederherstellen: kubectl apply -f rickroll.yaml"
      evidence "Kopien, die nicht starten" "${STUCK:-Ursache steht im Deployment-Status: $PROG_REASON}"
    fi
  else
    fail "Anwendung erstellt, aber keine Kopie ist bereit (${DESIRED} benötigt)" \
         "siehe kubectl get pods -l app=rickroll und kubectl describe deployment rickroll"
    evidence "Pod-Zustand" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
  fi
else
  fail "kein Deployment mit dem Namen rickroll gefunden" \
       "Manifest anwenden: kubectl apply -f rickroll.yaml"
fi

# --- Einstellungen und Seite ---------------------------------------------------
# Beide ConfigMaps werden von derselben Datei wie die Anwendung erzeugt, verschwinden können sie
# also nur zusammen mit ihr oder durch manuelles Löschen. Wir prüfen sie separat, damit bei einem
# Defekt der Seite der Teilnehmer sofort sieht, was genau fehlt: Ohne rickroll-conf setzt
# nginx den Pod-Namen nicht ein, und ohne rickroll-page-v1 gibt es nichts, womit man die
# zweite Version in Lab 4 vergleichen könnte, und nichts, wohin man zurückrollen kann.
for cm in rickroll-conf rickroll-page-v1; do
  if kubectl get configmap "$cm" >/dev/null 2>&1; then
    ok "Einstellungen vorhanden: ConfigMap ${cm}"
  else
    fail "ConfigMap ${cm} nicht gefunden" \
         "sie wird von derselben Datei erzeugt: kubectl apply -f rickroll.yaml"
  fi
done

# --- feste Adresse -------------------------------------------------------
if kubectl get service rickroll >/dev/null 2>&1; then
  # Ein Service ohne Endpoints ist ein typischer und unauffälliger Defekt: Das Objekt existiert,
  # aber die Pod-Labels stimmten nicht mit dem Selektor überein, und hinter der Adresse ist es leer.
  EPS="$(kubectl get endpoints rickroll -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
  EPS_N="$(printf '%s' "$EPS" | wc -w | tr -d ' ')"
  if [ "${EPS_N:-0}" -ge 1 ]; then
    ok "feste Adresse funktioniert, Kopien dahinter: ${EPS_N}"
    evidence "Adressen hinter dem Service" "$EPS"
  else
    fail "Service rickroll existiert, aber es steht keine einzige Kopie dahinter" \
         "meist liegt die Ursache darin, dass die Pod-Labels nicht mit dem selector des Service übereinstimmten — prüfe app: rickroll"
  fi
else
  fail "kein Service mit dem Namen rickroll gefunden" \
       "er wird von derselben Datei erzeugt: kubectl apply -f rickroll.yaml"
fi

# --- Kernpunkt: Die Seite wird wirklich ausgeliefert -------------------------------------
# Um dieser Prüfung willen war alles gedacht. Alle vorherigen sagen nur, dass die Objekte
# im Cluster korrekt beschrieben sind; diese — dass der Nutzer eine Seite bekommt. Die Anfrage geht
# VON INNERHALB des Clusters, über einen Einweg-Pod: Von außen existiert die Adresse rickroll nicht, und
# port-forward wäre hier eine Prüfung deines Laptops, nicht des Clusters.
# Wir fragen mehrmals an: Bei mehreren Kopien hinter dem Service trifft eine einzelne Stichprobe
# vielleicht nicht die ersetzte, und die Prüfung wird auf fremdem Inhalt grün.
BODY="$(in_cluster_curl_many 'http://rickroll/' 8)"
# Der Marker muss GENAU EINMAL pro Seite vorkommen, sonst lügt der Antwortzähler:
# „Never Gonna Give You Up" steht sowohl im <title> als auch im <h1> und ergab eine Verdopplung.
ANSWERS="$(printf '%s' "$BODY" | grep -c 'вас обслужил под')"
TOTAL_LINES="$(printf '%s' "$BODY" | grep -c '<title>')"
if [ "${ANSWERS:-0}" -ge 1 ] && [ "${ANSWERS:-0}" -eq "${TOTAL_LINES:-0}" ]; then
  ok "Anwendung antwortet über HTTP und liefert ihre eigene Seite aus (${ANSWERS} Anfragen geprüft)"
elif [ "${ANSWERS:-0}" -ge 1 ]; then
  fail "hinter dem Service antwortet nicht nur deine Anwendung: die eigene Seite kam ${ANSWERS} Mal von ${TOTAL_LINES}" \
       "jemand anderes trägt das Label app=rickroll — siehe kubectl get pods -l app=rickroll und entferne das Überzählige"
else
  fail "Anwendung hat die erwartete Seite nicht ausgeliefert" \
       "manuell prüfen: kubectl port-forward svc/rickroll 8080:80, dann http://localhost:8080 öffnen"
  evidence "Was statt der Seite zurückkam" "$(printf '%s' "$BODY" | head -20)"
fi

# --- Einsetzen des Pod-Namens -------------------------------------------------
# Um dessentwillen ist das Lab gemacht: Der Name in der Seite muss mit dem echten Pod übereinstimmen.
SERVED_BY="$(printf '%s' "$BODY" | grep -o '<b>[^<]*</b>' | head -1 | sed 's/<[^>]*>//g')"
# Wir nehmen die Pods, die vom ReplicaSet der Anwendung verwaltet werden, und NICHT alles, was das Label
# app=rickroll trägt. Sonst gelangt ein fremder Pod mit diesem Label in die Liste der „echten"
# und bestätigt sich selbst — geprüft, ein Hochstapler bestand die Prüfung auf diese Weise.
REAL_PODS="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
STRAY="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | awk '$2!="ReplicaSet" {print $1}')"
if [ -n "$STRAY" ]; then
  fail "fremde Pods tragen das Label app=rickroll — sie gelangen in die Lastverteilung" \
       "entferne das Überzählige: $(printf '%s' "$STRAY" | tr '\n' ' ')"
  evidence "Fremde Pods unter dem Anwendungs-Label" "$STRAY"
fi

if [ -z "$SERVED_BY" ]; then
  fail "in der Seite steht kein Pod-Name" \
       "prüfe, dass die ConfigMap rickroll-conf eingesetzt wurde — sie enthält die Zeile sub_filter '__POD__' '\$hostname'"
elif [ "$SERVED_BY" = "__POD__" ]; then
  fail "Pod-Name wurde nicht eingesetzt — in der Seite ist der Platzhalter __POD__ geblieben" \
       "nginx hat sub_filter nicht angewendet: prüfe, dass das Volume mit den Einstellungen unter /etc/nginx/conf.d gemountet ist"
elif printf '%s' "$REAL_PODS" | grep -qx "$SERVED_BY"; then
  ok "Pod-Name wird eingesetzt und stimmt mit einer wirklich laufenden Kopie überein: ${SERVED_BY}"
  evidence "Wer die Anfrage bedient hat" "$SERVED_BY"
  evidence "Laufende Kopien" "$REAL_PODS"
else
  fail "die Seite nennt den Pod «${SERVED_BY}», aber einen solchen Pod gibt es im Cluster nicht" \
       "die Kopie wurde vielleicht zwischen Anfrage und Prüfung neu erstellt — starte das Skript noch einmal"
fi

# --- Bereitschaftsprüfung konfiguriert ------------------------------------------
# Ohne sie gibt es im Lab über Versions-Rollouts eine Ausfallzeit, und der Teilnehmer wird meinen, wir hätten gelogen.
PROBE_PATH="$(kubectl get deployment rickroll \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE_PATH" ]; then
  ok "Bereitschaftsprüfung konfiguriert (${PROBE_PATH}) — das Update läuft ohne Ausfallzeit"
else
  warn "die Anwendung hat keine Bereitschaftsprüfung" \
       "Lab 4 über Updates ohne Ausfallzeit wird bei einer solchen Anwendung Fehler erzeugen — stelle readinessProbe aus rickroll.yaml wieder her"
fi

finish
