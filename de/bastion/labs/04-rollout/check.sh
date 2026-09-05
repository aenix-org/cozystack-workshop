#!/usr/bin/env bash
# Prüfung für Lab 4: Ausrollen einer neuen Version und Rollback.
#
# Wir prüfen die Substanz, nicht die eingegebenen Befehle:
#   - die Anwendungshistorie enthält mehrere Revisionen, d.h. die Version wurde tatsächlich geändert;
#   - der ConfigMap der zweiten Version liegt als eigenes Objekt im Cluster, nicht als Änderung des ersten;
#   - der Container hat eine readinessProbe — ohne sie ist Zero-Downtime nicht reproduzierbar;
#   - das Ausrollen lief vollständig durch und blieb nicht stecken;
#   - die vom Service ausgelieferte Seite entspricht dem ConfigMap, auf den die
#     Spezifikation verweist. Das fängt den Fall ab „die Spezifikation wurde zurückgerollt, aber die Pods wurden nicht neu erstellt".
#
# Das Skript ändert nichts. Der Einweg-Pod wird nur benötigt, um die Seite
# aus dem Cluster heraus abzurufen, und entfernt sich selbst.
#
# Läuft auf der VM, aus dem Ordner dieses Labs, mit Zugriff auf den Trainingscluster `lab`
# (nicht auf den Tenant im Management-Cluster):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/04-rollout && ./check.sh
# Die Variable COZY_TENANT wird hier nicht benötigt: das gesamte Lab läuft im Cluster `lab`.
#
# Führe es VOR dem Aufräumen aus und nachdem der Rollback abgeschlossen ist: die Revisionshistorie lebt
# zusammen mit dem Deployment und verschwindet zusammen mit ihm.

# Diese gehen in den Berichtskopf und in den Dateinamen report-<lab>-<datum>.md neben dem Skript.
LAB_NAME="04-rollout"
LAB_TITLE="Lab 4 · Ausrollen einer neuen Version und Rollback"
# Gemeinsame Bibliothek: ok / fail / warn / evidence / finish, Anfragen aus dem Cluster heraus,
# Schreiben des Berichts. Der Pfad wird vom Speicherort des Skripts selbst berechnet, nicht vom aktuellen Verzeichnis.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Ohne KUBECONFIG sucht kubectl einen Cluster auf der VM und lässt alles mit einem einzigen Fehler scheitern,
# in dem die wahre Ursache nicht zu erkennen ist. Wir stoppen sofort.
need_kubeconfig

APP=rickroll

# --- Anwendung ist vorhanden und in einem funktionierenden Zustand ------------------
# Ohne die Anwendung gibt es nichts zu prüfen, daher ist dies der einzige vorzeitige Ausstieg.
# Weiter unten schauen wir nicht nur auf die Anzahl der bereiten Kopien, sondern auch auf den Grund in der
# Progressing-Bedingung: NewReplicaSetAvailable bedeutet, dass das Ausrollen ABGESCHLOSSEN ist. Bereite Kopien
# allein reichen nicht — bei einem steckengebliebenen Update läuft die alte Version, der Zähler
# zeigt die erwartete Zahl, doch die neue Kopie ist kein einziges Mal hochgekommen.
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "Anwendung ${APP} ist nicht im Cluster" \
       "rolle sie aus: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

PROG_REASON="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.reason}{end}' 2>/dev/null)"

if [ "$HAVE" = "$WANT" ] && [ "${HAVE:-0}" -ge 1 ] && [ "$PROG_REASON" = "NewReplicaSetAvailable" ]; then
  ok "Ausrollen lief vollständig durch: ${HAVE} von ${WANT} Kopien bereit"
else
  fail "Anwendung ist nicht im abgeschlossenen Zustand (${HAVE} von ${WANT} bereit, Grund: ${PROG_REASON:-keiner})" \
       "wenn das Ausrollen steckt — steige per Rollback aus: kubectl rollout undo deployment/${APP}"
fi
evidence "Zustand der Anwendung" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- readinessProbe: das, womit Zero-Downtime bezahlt wird -----------------------
PROBE="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE" ]; then
  ok "der Container hat eine readinessProbe (${PROBE}) — Kopien werden erst nach ihrer Bereitschaft ersetzt"
else
  fail "der Container hat keine readinessProbe" \
       "ohne sie schickt der Cluster Traffic an eine nicht bereite Kopie; wende ../01-deploy/rickroll.yaml an"
fi

# --- Versionen als separate Objekte erstellt --------------------------------------
# Beide Versionen der Seite müssen als zwei separate ConfigMaps im Cluster liegen.
# Wer stattdessen rickroll-page-v1 direkt bearbeitet hat, sieht die neue Seite auf dem Bildschirm
# und entscheidet, dass das Lab erledigt ist — aber es gibt nirgendwohin zurückzurollen,
# und es findet weder ein Kopientausch noch ein Eintrag in der Revisionshistorie statt.
if kubectl get configmap rickroll-page-v2 >/dev/null 2>&1; then
  ok "ConfigMap rickroll-page-v2 liegt als separates Objekt im Cluster"
else
  fail "es gibt keinen ConfigMap rickroll-page-v2 im Cluster" \
       "wende ihn an: kubectl apply -f rickroll-page-v2.yaml"
fi

if kubectl get configmap rickroll-page-v1 >/dev/null 2>&1; then
  ok "die erste Version der Seite ist ebenfalls erhalten — es gibt ein Ziel für den Rollback"
else
  warn "ConfigMap rickroll-page-v1 nicht im Cluster gefunden" \
       "ein Rollback auf die erste Version bringt ohne ihn die Pods nicht hoch: kubectl apply -f ../01-deploy/rickroll.yaml"
fi

# --- Revisionshistorie -------------------------------------------------------
# Wir schauen auf die NUMMER der letzten Revision, nicht auf die Anzahl der Zeilen in der Historie. Ein Rollback
# fügt kein neues ReplicaSet hinzu — er verwendet das alte wieder und erhöht dessen Nummer,
# daher gibt es nach einem Rollback genauso viele Zeilen in der Historie, während die Nummer wächst.
#   1 — die Spezifikation wurde nie geändert
#   2 — die Version wurde umgeschaltet
#   3 und mehr — umgeschaltet und zurückgerollt
REV_MAX="$(kubectl rollout history deployment/${APP} 2>/dev/null \
  | awk '$1 ~ /^[0-9]+$/ { if ($1+0 > m) m = $1+0 } END { print m+0 }')"
[ -z "$REV_MAX" ] && REV_MAX=0

if [ "$REV_MAX" -ge 3 ]; then
  ok "die letzte Revision der Anwendung ist ${REV_MAX}: die Version wurde umgeschaltet und zurückgerollt"
elif [ "$REV_MAX" -eq 2 ]; then
  warn "letzte Revision ist 2: das Ausrollen ist erledigt, der Rollback noch nicht" \
       "stelle die erste Version wieder her: kubectl rollout undo deployment/${APP}"
else
  fail "letzte Revision ist ${REV_MAX}: die Spezifikation der Anwendung wurde nie geändert" \
       "schalte das Volume mit dem Patch aus dem Lab auf die zweite Version um, dann rolle zurück"
fi
evidence "Revisionshistorie" "$(kubectl rollout history deployment/${APP} 2>/dev/null)"

# --- auf welche Version die Spezifikation zeigt --------------------------------------
# Wir suchen das Volume ÜBER DEN NAMEN page, obwohl der Patch im Lab es über den Index adressiert.
# Genau der Unterschied wird hier abgefangen: wenn der Patch ins falsche Listenelement ging,
# zeigt der Name page auf den vorherigen ConfigMap oder verschwindet, und der Teilnehmer erfährt
# davon in Worten, statt durch einen seltsamen nginx-Fehler.
VOL_CM="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.volumes[?(@.name=="page")]}{.configMap.name}{end}' 2>/dev/null)"

case "$VOL_CM" in
  rickroll-page-v1)
    ok "die Spezifikation der Anwendung wurde auf die erste Version der Seite zurückgerollt"
    ;;
  rickroll-page-v2)
    warn "die Spezifikation der Anwendung zeigt auf die zweite Version der Seite" \
         "das Lab endet mit einem Rollback; wenn das so beabsichtigt ist — kein Grund zur Sorge, andernfalls: kubectl rollout undo deployment/${APP}"
    ;;
  "")
    fail "die Spezifikation hat kein Volume namens page" \
         "sieht aus, als sei der Patch am falschen Ort gelandet (Adressierung über Index!); wende ../01-deploy/rickroll.yaml erneut an"
    ;;
  *)
    fail "Volume page zeigt auf ConfigMap ${VOL_CM}, den das Lab nicht erstellt hat" \
         "rolle zurück: kubectl rollout undo deployment/${APP}"
    ;;
esac

# --- was tatsächlich an den Client ausgeliefert wird ------------------------------------
# Die aussagekräftigste Prüfung: wir vergleichen die Spezifikation mit dem, was der Nutzer sieht.
# Eine Abweichung hier bedeutet, dass die Pods nicht für die neue Spezifikation neu erstellt wurden.
# Acht Anfragen, nicht eine. Hinter dem Service stehen drei Kopien; wenn das Ausrollen nicht vollständig konvergiert ist,
# trifft eine einzelne Anfrage mit einer Wahrscheinlichkeit von einem Drittel die richtige Version und verdeckt die Abweichung.
BODIES="$(in_cluster_curl_many "http://${APP}/" 8)"
BODY="$BODIES"

if [ -z "$BODY" ]; then
  fail "Service ${APP} hat aus dem Cluster heraus keine Seite zurückgegeben" \
       "prüfe die Endpoints: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
else
  # Wir erkennen beide Versionen POSITIV, jede an ihrem eigenen Marker. Der Zweig „wenn nicht v2, dann
  # v1" zählte alles als erste Version: die nginx-Standardseite, einen 404, eine fremde
  # Anwendung, Müll — geprüft, bei Müll gab das Skript „LAB BESTANDEN" aus.
  if printf '%s' "$BODY" | grep -q 'VERSION 2'; then
    SERVED_VER="rickroll-page-v2"
  elif printf '%s' "$BODY" | grep -q 'Never Gonna Give You Up'; then
    SERVED_VER="rickroll-page-v1"
  else
    SERVED_VER=""
    fail "unter der Service-Adresse wird etwas anderes als die Anwendungsseite ausgeliefert" \
         "kein einziger bekannter Marker in der Antwort — stelle das Original wieder her: kubectl apply -f ../01-deploy/rickroll.yaml"
    evidence "Was anstelle der Seite zurückkam" "$(printf '%s' "$BODY" | head -12)"
  fi

  if [ -n "$VOL_CM" ] && [ "$SERVED_VER" = "$VOL_CM" ]; then
    ok "dem Client wird genau die Version ausgeliefert, die in der Spezifikation vermerkt ist (${SERVED_VER})"
  elif [ -n "$VOL_CM" ]; then
    fail "die Spezifikation zeigt auf ${VOL_CM}, aber dem Client wird ${SERVED_VER} ausgeliefert" \
         "die Kopien wurden nicht für die neue Spezifikation neu erstellt: kubectl rollout status deployment/${APP}"
  fi

  if printf '%s' "$BODY" | grep -q '__POD__'; then
    fail "der Kopienname wird nicht in die Seite eingesetzt" \
         "ConfigMap rickroll-conf ist verloren: wende ../01-deploy/rickroll.yaml vollständig an"
  else
    SERVED_POD="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
    if [ -n "$SERVED_POD" ] && kubectl get pod "$SERVED_POD" >/dev/null 2>&1; then
      ok "die Seite wurde von einer lebenden Kopie ${SERVED_POD} ausgeliefert"
    else
      warn "der Name aus der Seite konnte keiner laufenden Kopie zugeordnet werden" \
           "wahrscheinlich änderten sich die Kopien genau während der Prüfung — führe das Skript erneut aus"
    fi
  fi

  evidence "Ausgelieferte Seite (Fragment)" \
    "$(printf '%s' "$BODY" | grep -o '<h1>[^<]*</h1>' | head -1)
$(printf '%s' "$BODY" | grep -o "bedient von Pod<b>${APP}-[a-z0-9-]*</b>" | head -1)"
fi

# --- Bereitschaft für die nächsten Labs ------------------------------------------
# Das Lab skalierte die Kopien auf drei hoch, damit der Austausch stückweise sichtbar war. Die drei
# übriggebliebenen Kopien brechen nichts — daher ein warn, kein fail — aber sie belegen Platz auf dem
# Trainingsknoten, der den benachbarten Labs weiter unten fehlen wird.
if [ "$WANT" = "1" ]; then
  ok "die Anzahl der Kopien wurde auf eine zurückgesetzt"
else
  warn "aktuell angeforderte Kopien: ${WANT}" \
       "nach dem Lab lohnt es, auf eine zurückzugehen: kubectl scale deployment ${APP} --replicas=1"
fi

finish
