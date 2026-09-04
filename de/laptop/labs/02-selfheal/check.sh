#!/usr/bin/env bash
# Prüfung von Lab 2: Selbstheilung.
#
# Wir prüfen nicht «die Befehle wurden eingetippt», sondern den Cluster-Zustand nach dem Lab: die App
# bedient wieder Anfragen über den Service, gibt den Namen ihrer Kopie zurück, und dieser Name gehört
# einem tatsächlich laufenden Pod. Außerdem suchen wir nach Spuren, dass Kopien neu erstellt wurden.
#
# Das Skript löscht und erstellt nichts, außer einem einmaligen Pod zur Prüfung der
# Service-Erreichbarkeit von innerhalb des Clusters — er entfernt sich selbst.

LAB_NAME="02-selfheal"
LAB_TITLE="Lab 2 · Einen Pod töten und sehen, was passiert"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

APP=rickroll

# RFC3339 aus kubectl (immer UTC mit Z) in Unix-Sekunden. Über python3, weil
# BSD date auf macOS und GNU date auf Linux Datumsangaben unterschiedlich parsen, und python überall da ist,
# wo lib.sh funktioniert.
_epoch() {
  python3 -c 'import sys,datetime as d;print(int(d.datetime.strptime(sys.argv[1],
"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=d.timezone.utc).timestamp()))' "$1" 2>/dev/null
}

# --- die App existiert überhaupt -------------------------------------------
DEP_TS="$(kubectl get deployment "$APP" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"

if [ -z "$DEP_TS" ]; then
  fail "App ${APP} ist nicht im Cluster" \
       "am Ende des Labs musste sie wiederhergestellt werden: kubectl apply -f ../01-deploy/rickroll.yaml"
  evidence "Was im Namespace ist" "$(kubectl get deployment,rs,pods 2>/dev/null)"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

if [ "${HAVE:-0}" -ge 1 ] && [ "$HAVE" = "$WANT" ]; then
  ok "App ${APP} wiederhergestellt: bereite Kopien ${HAVE} von ${WANT}"
else
  fail "Kopien bereit ${HAVE} von den angeforderten ${WANT}" \
       "siehe kubectl describe deployment ${APP} und kubectl get pods -l app=${APP}"
fi
evidence "Zustand der App" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- die Kette Deployment -> ReplicaSet -> Pod -----------------------------
# Der Sinn des Labs ist, dass die Kopie vom ReplicaSet zurückgebracht wird, nicht «vom Cluster im Allgemeinen».
# Wenn der Besitzer des Pods sich als kein ReplicaSet herausstellt, hat der Teilnehmer den Pod von Hand erstellt,
# und wird die Selbstheilung nicht sehen.
# Wir zählen die Pods namentlich, statt eindeutige Besitzer-Arten zu sammeln: bei einem Pod ohne
# ownerReferences gibt jsonpath einen leeren String zurück, `sort -u` kollabiert ihn zu einem unsichtbaren
# Element, und `*ReplicaSet*` matcht, solange mindestens ein Pod von einem ReplicaSet verwaltet wird.
# Dadurch bestand ein fremder, von Hand erstellter Pod die Prüfung unbemerkt.
PODS_TOTAL="$(kubectl get pods -l app=${APP} --no-headers 2>/dev/null | grep -c . )"
PODS_BY_RS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -c . )"
OWNER_KINDS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | sort -u | tr '\n' ' ')"

case "${PODS_TOTAL}:${PODS_BY_RS}" in
  0:*)
    fail "es gibt keinen Pod mit dem Label app=${APP}" \
         "stellen Sie die App wieder her: kubectl apply -f ../01-deploy/rickroll.yaml"
    ;;
  *:0)
    fail "kein ${APP}-Pod wird von einem ReplicaSet verwaltet — es wird keine Selbstheilung geben" \
         "sieht so aus, als wäre der Pod von Hand erstellt worden (kubectl run). Löschen Sie ihn und wenden Sie ../01-deploy/rickroll.yaml an"
    ;;
  *)
    if [ "$PODS_TOTAL" -ne "$PODS_BY_RS" ]; then
      fail "das Label app=${APP} tragen fremde Pods: ${PODS_BY_RS} von ${PODS_TOTAL} werden von einem ReplicaSet verwaltet" \
           "die übrigen landen im Load-Balancing und liefern eine fremde Antwort — finden Sie sie: kubectl get pods -l app=${APP} -o wide"
      evidence "Besitzer der Pods" \
        "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null)"
    else
    ok "die Kopien werden von einem ReplicaSet verwaltet — die Kette Deployment → ReplicaSet → Pod ist intakt"
    evidence "Wer wessen Besitzer ist" \
      "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null)"
    fi
    ;;
esac

# --- Spuren der Neuerstellung von Kopien -----------------------------------
# Direkte Beweise «der Pod wurde getötet» bewahrt der Cluster nicht auf. Es gibt zwei indirekte, und beide sind ausreichend:
# der Pod ist merklich jünger als sein Deployment, und in den Events des ReplicaSet gibt es mehr als eine Erstellung.
POD_TS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null)"

DEP_E="$(_epoch "$DEP_TS")"
POD_E="$(_epoch "$POD_TS")"

if [ -n "$DEP_E" ] && [ -n "$POD_E" ]; then
  DELTA=$(( POD_E - DEP_E ))
  if [ "$DELTA" -ge 45 ]; then
    ok "die Kopie ist um ${DELTA} s jünger als die App — also wurde die vorherige entfernt und diese stattdessen erstellt"
  else
    warn "die Kopie ist fast gleich alt wie die App (Differenz ${DELTA} s)" \
         "wenn Sie die App ganz am Ende komplett wiederhergestellt haben — ist das normal; sonst wurde der Schritt mit dem Löschen des Pods nicht ausgeführt"
  fi
  evidence "Alter der Objekte" "deployment erstellt: ${DEP_TS}
pod erstellt:        ${POD_TS}
Differenz:           ${DELTA} s"
else
  warn "Alter von Pod und App konnte nicht verglichen werden" \
       "python3 wird im PATH benötigt; auf das Bestehen des Labs hat das keinen Einfluss"
fi

# Events leben etwa eine Stunde, daher ist ihr Fehlen kein Durchfallen, sondern eine Anmerkung.
CREATES="$(kubectl get events \
  --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet \
  --no-headers 2>/dev/null | grep -c "$APP")"
[ -z "$CREATES" ] && CREATES=0

if [ "$CREATES" -ge 2 ]; then
  ok "in den Cluster-Events ${CREATES} Erstellungen der Kopie — die Selbstheilung hat tatsächlich funktioniert"
  evidence "Events der Kopie-Erstellung" \
    "$(kubectl get events --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet 2>/dev/null | grep "$APP" | tail -10)"
else
  warn "in den Cluster-Events ist die Erstellung der Kopie nur ${CREATES} Mal sichtbar" \
       "Events werden etwa eine Stunde aufbewahrt und könnten abgelaufen sein"
fi

# Keines der beiden Anzeichen ist für sich allein blockierend: Events leben etwa eine Stunde,
# und das Alter stimmt bei dem überein, der die App am Ende des Labs rechtmäßig komplett wiederhergestellt hat.
# Aber wenn KEINES zutrifft — wurde die Kopie überhaupt nicht gelöscht, und das Lab ist nicht gemacht. Ohne diese
# Verknüpfung druckte das Skript «LAB BESTANDEN» gleich nach Lab 1, ohne auf eine einzige Löschung zu warten.
if [ "${DELTA:-0}" -lt 45 ] && [ "$CREATES" -lt 2 ]; then
  fail "keine Spuren von Selbstheilung gefunden: die Kopie wurde nicht gelöscht" \
       "löschen Sie die Kopie: kubectl delete pod -l app=${APP} — und starten Sie die Prüfung innerhalb einer Stunde, solange die Events leben"
fi

# --- der Service bedient tatsächlich ---------------------------------------
# Die wichtigste inhaltliche Prüfung: nicht «das Objekt existiert», sondern «über den Service kommt eine Seite
# und darin steht der Name einer lebenden Kopie».
BODY="$(in_cluster_curl "http://${APP}/")"

if [ -z "$BODY" ]; then
  fail "Service ${APP} hat von innerhalb des Clusters keine Seite geliefert" \
       "prüfen Sie die Endpoints: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
elif printf '%s' "$BODY" | grep -q '__POD__'; then
  fail "die Seite wird geliefert, aber der Name der Kopie wurde nicht eingesetzt" \
       "die ConfigMap rickroll-conf ist verloren: wenden Sie ../01-deploy/rickroll.yaml vollständig an"
else
  SERVED="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
  if [ -z "$SERVED" ]; then
    fail "in der Antwort des Service fehlt der Name der Kopie" \
         "die Seite kam nicht von unserer App — prüfen Sie kubectl get svc ${APP} -o yaml"
  elif kubectl get pod "$SERVED" >/dev/null 2>&1; then
    ok "der Service liefert eine Seite, sie wurde von der lebenden Kopie ${SERVED} bedient"
    evidence "Antwort des Service (Fragment)" \
      "$(printf '%s' "$BODY" | grep -o "вас обслужил под<b>${APP}-[a-z0-9-]*</b>" | head -1)"
  else
    fail "die Seite wurde von der Kopie ${SERVED} geliefert, aber einen solchen Pod gibt es im Cluster nicht mehr" \
         "warten Sie ein Dutzend Sekunden und starten Sie die Prüfung erneut — wahrscheinlich wechselte die Kopie gerade eben"
  fi
fi

# --- Bereitschaft für das nächste Lab --------------------------------------
if [ "$WANT" = "1" ]; then
  ok "die Anzahl der Kopien wurde auf eine zurückgesetzt — Lab 3 beginnt mit einem sauberen Blatt"
else
  warn "aktuell angefordert Kopien: ${WANT}" \
       "stellen Sie vor Lab 3 eine wieder her: kubectl scale deployment ${APP} --replicas=1"
fi

finish
