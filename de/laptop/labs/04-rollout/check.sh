#!/usr/bin/env bash
# Prüfung für Lab 4: Ausrollen einer neuen Version und Rollback.
#
# Wir prüfen die Substanz, nicht die eingetippten Befehle:
#   - die App-Historie hat mehrere Revisionen, d. h. die Version wurde wirklich geändert;
#   - der ConfigMap der zweiten Version liegt als eigenständiges Objekt im Cluster, nicht als Bearbeitung des ersten;
#   - der Container hat eine readinessProbe — ohne sie ist Zero-Downtime nicht reproduzierbar;
#   - das Ausrollen ist abgeschlossen, nicht steckengeblieben;
#   - die Seite, die der Service ausliefert, entspricht dem ConfigMap, auf den die
#     Spezifikation verweist. Das fängt den Fall ab: „die Spezifikation wurde zurückgerollt, die Pods aber nicht neu erstellt“.
#
# Das Skript ändert nichts. Der Einweg-Pod wird nur benötigt, um die Seite von
# innerhalb des Clusters abzuholen, und entfernt sich selbst.
#
# Läuft auf dem Laptop, aus dem Ordner dieses Labs, über den Zugriff auf den Schulungscluster `lab`
# (nicht auf den Tenant im Management-Cluster):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/04-rollout && ./check.sh
# Die Variable COZY_TENANT wird hier nicht benötigt: das gesamte Lab läuft innerhalb des Clusters `lab`.
#
# VOR dem Aufräumen und nachdem das Rollback abgeschlossen ist ausführen: die Revisionshistorie lebt
# zusammen mit dem Deployment und verschwindet zusammen mit ihm.

# Landen im Berichtskopf und im Dateinamen report-<lab>-<datum>.md neben dem Skript.
LAB_NAME="04-rollout"
LAB_TITLE="Lab 4 · Ausrollen einer neuen Version und Rollback"
# Gemeinsame Bibliothek: ok / fail / warn / evidence / finish, Anfragen von innerhalb des Clusters,
# Schreiben des Berichts. Der Pfad wird vom Ort des Skripts selbst aus aufgelöst, nicht vom aktuellen Verzeichnis.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Ohne KUBECONFIG sucht kubectl einen Cluster auf dem Laptop und lässt alles mit einem einzigen Fehler
# scheitern, in dem die eigentliche Ursache nicht zu erkennen ist. Wir stoppen sofort.
need_kubeconfig

APP=rickroll

# --- die App ist vorhanden und in einen funktionsfähigen Zustand gebracht ------------------
# Ohne App gibt es nichts zu prüfen, daher ist dies der einzige vorzeitige Ausstieg.
# Danach schauen wir nicht nur auf die Anzahl bereiter Kopien, sondern auch auf den Grund in der
# Progressing-Bedingung: NewReplicaSetAvailable bedeutet, dass das Ausrollen ABGESCHLOSSEN ist. Bereite
# Kopien allein reichen nicht — bei einem steckengebliebenen Update läuft die alte Version, der Zähler
# zeigt die erwartete Anzahl, während die neue Kopie überhaupt nie hochkam.
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "App ${APP} ist nicht im Cluster" \
       "rollen Sie sie aus: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

PROG_REASON="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.reason}{end}' 2>/dev/null)"

if [ "$HAVE" = "$WANT" ] && [ "${HAVE:-0}" -ge 1 ] && [ "$PROG_REASON" = "NewReplicaSetAvailable" ]; then
  ok "Ausrollen abgeschlossen: ${HAVE} von ${WANT} Kopien bereit"
else
  fail "App ist nicht in abgeschlossenem Zustand (${HAVE} von ${WANT} bereit, Grund: ${PROG_REASON:-keiner})" \
       "wenn das Ausrollen steckt — mit einem Rollback erholen: kubectl rollout undo deployment/${APP}"
fi
evidence "Zustand der App" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- readinessProbe: das, womit Zero-Downtime bezahlt wird -----------------------
PROBE="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE" ]; then
  ok "der Container hat eine readinessProbe (${PROBE}) — Kopien werden erst nach ihrer Bereitschaft ausgetauscht"
else
  fail "der Container hat keine readinessProbe" \
       "ohne sie leitet der Cluster Traffic auf eine nicht bereite Kopie; wenden Sie ../01-deploy/rickroll.yaml an"
fi

# --- Versionen als getrennte Objekte erstellt --------------------------------------
# Beide Versionen der Seite müssen im Cluster als zwei getrennte ConfigMaps liegen.
# Wer stattdessen rickroll-page-v1 an Ort und Stelle bearbeitet hat, sieht die neue Seite auf dem Bildschirm
# und entscheidet, dass das Lab erledigt ist — aber es wird kein Ziel zum Zurückrollen geben,
# und weder ein Kopientausch noch ein Eintrag in der Revisionshistorie findet überhaupt statt.
if kubectl get configmap rickroll-page-v2 >/dev/null 2>&1; then
  ok "ConfigMap rickroll-page-v2 liegt als eigenständiges Objekt im Cluster"
else
  fail "ConfigMap rickroll-page-v2 ist nicht im Cluster" \
       "wenden Sie ihn an: kubectl apply -f rickroll-page-v2.yaml"
fi

if kubectl get configmap rickroll-page-v1 >/dev/null 2>&1; then
  ok "auch die erste Version der Seite ist erhalten — es gibt ein Ziel zum Zurückrollen"
else
  warn "ConfigMap rickroll-page-v1 im Cluster nicht gefunden" \
       "ein Rollback auf die erste Version bringt die Pods ohne ihn nicht hoch: kubectl apply -f ../01-deploy/rickroll.yaml"
fi

# --- Revisionshistorie -------------------------------------------------------
# Wir betrachten die NUMMER der letzten Revision, nicht die Anzahl der Zeilen in der Historie. Ein Rollback
# fügt kein neues ReplicaSet hinzu — es verwendet das alte wieder und erhöht dessen Nummer,
# daher hat die Historie nach einem Rollback gleich viele Zeilen, aber die Nummer wächst.
#   1 — die Spezifikation wurde nie geändert
#   2 — die Version wurde umgeschaltet
#   3 und mehr — umgeschaltet und zurückgesetzt
REV_MAX="$(kubectl rollout history deployment/${APP} 2>/dev/null \
  | awk '$1 ~ /^[0-9]+$/ { if ($1+0 > m) m = $1+0 } END { print m+0 }')"
[ -z "$REV_MAX" ] && REV_MAX=0

if [ "$REV_MAX" -ge 3 ]; then
  ok "die letzte Revision der App ist ${REV_MAX}: die Version wurde umgeschaltet und zurückgesetzt"
elif [ "$REV_MAX" -eq 2 ]; then
  warn "letzte Revision ist 2: Ausrollen erledigt, Rollback noch nicht" \
       "stellen Sie die erste Version wieder her: kubectl rollout undo deployment/${APP}"
else
  fail "letzte Revision ist ${REV_MAX}: die Spezifikation der App wurde nie geändert" \
       "schalten Sie das Volume mit dem Patch aus dem Lab auf die zweite Version um, dann rollen Sie zurück"
fi
evidence "Revisionshistorie" "$(kubectl rollout history deployment/${APP} 2>/dev/null)"

# --- auf welche Version die Spezifikation zeigt --------------------------------------
# Wir suchen das Volume NACH DEM NAMEN page, obwohl der Patch im Lab es über den Index adressiert. Der
# Unterschied wird genau hier gefangen: wenn der Patch beim falschen Listenelement gelandet ist, zeigt der
# Name page auf den vorherigen ConfigMap oder verschwindet, und der Teilnehmer erfährt davon in Worten, nicht
# durch einen seltsamen nginx-Fehler.
VOL_CM="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.volumes[?(@.name=="page")]}{.configMap.name}{end}' 2>/dev/null)"

case "$VOL_CM" in
  rickroll-page-v1)
    ok "die Spezifikation der App wurde auf die erste Version der Seite zurückgesetzt"
    ;;
  rickroll-page-v2)
    warn "die Spezifikation der App zeigt auf die zweite Version der Seite" \
         "das Lab endet mit einem Rollback; wenn das so gewollt ist — kein Problem, sonst: kubectl rollout undo deployment/${APP}"
    ;;
  "")
    fail "in der Spezifikation gibt es kein Volume mit dem Namen page" \
         "es sieht aus, als sei der Patch an die falsche Stelle geraten (Adressierung über den Index!); wenden Sie ../01-deploy/rickroll.yaml erneut an"
    ;;
  *)
    fail "das Volume page zeigt auf ConfigMap ${VOL_CM}, den das Lab nicht erstellt hat" \
         "rollen Sie zurück: kubectl rollout undo deployment/${APP}"
    ;;
esac

# --- was dem Client tatsächlich ausgeliefert wird ------------------------------------
# Die aussagekräftigste Prüfung: wir gleichen die Spezifikation mit dem ab, was der Nutzer sieht.
# Eine Abweichung hier bedeutet, dass die Pods nicht für die neue Spezifikation neu erstellt wurden.
# Acht Anfragen, nicht eine. Hinter dem Service sitzen drei Kopien; wenn das Ausrollen nicht vollständig konvergierte,
# trifft eine einzelne Anfrage mit einer Wahrscheinlichkeit von einem Drittel die richtige Version und verdeckt die Abweichung.
BODIES="$(in_cluster_curl_many "http://${APP}/" 8)"
BODY="$BODIES"

if [ -z "$BODY" ]; then
  fail "Service ${APP} hat von innerhalb des Clusters keine Seite ausgeliefert" \
       "prüfen Sie die Endpoints: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
else
  # Wir bestimmen beide Versionen POSITIV, jede an ihrem eigenen Marker. Der Zweig „wenn nicht v2, dann
  # v1“ zählte alles als erste Version: die Standard-nginx-Seite, ein 404, eine fremde
  # App, Müll — geprüft, bei Müll meldete das Skript „LAB BESTANDEN“.
  if printf '%s' "$BODY" | grep -q 'VERSION 2'; then
    SERVED_VER="rickroll-page-v2"
  elif printf '%s' "$BODY" | grep -q 'Never Gonna Give You Up'; then
    SERVED_VER="rickroll-page-v1"
  else
    SERVED_VER=""
    fail "unter der Service-Adresse wird nicht die Seite der App ausgeliefert" \
         "kein bekannter Marker in der Antwort — stellen Sie das Original wieder her: kubectl apply -f ../01-deploy/rickroll.yaml"
    evidence "Was statt der Seite zurückkam" "$(printf '%s' "$BODY" | head -12)"
  fi

  if [ -n "$VOL_CM" ] && [ "$SERVED_VER" = "$VOL_CM" ]; then
    ok "dem Client wird genau die Version ausgeliefert, die in der Spezifikation steht (${SERVED_VER})"
  elif [ -n "$VOL_CM" ]; then
    fail "die Spezifikation zeigt auf ${VOL_CM}, dem Client wird aber ${SERVED_VER} ausgeliefert" \
         "die Kopien wurden nicht für die neue Spezifikation neu erstellt: kubectl rollout status deployment/${APP}"
  fi

  if printf '%s' "$BODY" | grep -q '__POD__'; then
    fail "der Name der Kopie wird nicht in die Seite eingesetzt" \
         "ConfigMap rickroll-conf ist verloren: wenden Sie die gesamte ../01-deploy/rickroll.yaml an"
  else
    SERVED_POD="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
    if [ -n "$SERVED_POD" ] && kubectl get pod "$SERVED_POD" >/dev/null 2>&1; then
      ok "die Seite wurde von einer lebendigen Kopie ${SERVED_POD} ausgeliefert"
    else
      warn "der Name aus der Seite konnte keiner laufenden Kopie zugeordnet werden" \
           "wahrscheinlich wechselten die Kopien während der Prüfung — führen Sie das Skript erneut aus"
    fi
  fi

  evidence "Ausgelieferte Seite (Auszug)" \
    "$(printf '%s' "$BODY" | grep -o '<h1>[^<]*</h1>' | head -1)
$(printf '%s' "$BODY" | grep -o "bedient von Pod<b>${APP}-[a-z0-9-]*</b>" | head -1)"
fi

# --- Bereitschaft für die nächsten Labs ------------------------------------
# Das Lab erhöhte die Kopien auf drei, damit der Tausch Stück für Stück sichtbar war. Drei zurückgelassene
# Kopien brechen nichts — daher warn, nicht fail — belegen aber Platz auf dem Schulungs-
# knoten, der den benachbarten Labs später nicht ausreicht.
if [ "$WANT" = "1" ]; then
  ok "die Anzahl der Kopien wurde auf eine zurückgesetzt"
else
  warn "aktuell angeforderte Kopien: ${WANT}" \
       "nach dem Lab sollte man auf eine zurückkehren: kubectl scale deployment ${APP} --replicas=1"
fi

finish
