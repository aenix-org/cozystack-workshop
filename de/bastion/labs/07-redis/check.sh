#!/usr/bin/env bash
# Prüfung für Lab 7: Der Cache beschleunigt wirklich, und das zeigt sich in den Zahlen.
#
# Die Hauptprüfung ist hier verhaltensbasiert, nicht strukturell. Das Skript nimmt selbst einen
# ungenutzten Identifikator, fragt ihn zweimal ab und beobachtet: Beim ersten Mal soll es einen
# Miss von Hunderten Millisekunden geben, beim zweiten — einen Hit von einstelligen Millisekunden.
# Ein Manifest mit den richtigen Umgebungsvariablen besteht diese Prüfung nicht, wenn der Cache
# nicht tatsächlich antwortet.
#
# Zwei Cluster: KUBECONFIG — dein Lab-Cluster, COZY_KUBECONFIG — der Cozystack-Management-Cluster,
# auf dem der managed Redis-Dienst läuft.

# LAB_NAME und LAB_TITLE landen im Kopf des Berichts. Danach wird die gemeinsame Prüf-Bibliothek
# eingebunden: aus ihr kommen ok / warn / fail / evidence / finish und, am wichtigsten,
# in_cluster_curl — sie startet einen Einweg-Pod mit curl INNERHALB des Clusters. Von innen,
# nicht von der VM: die Lab-Dienste sind nicht nach außen exponiert, passes-api ist per Name
# nur aus dem Cluster erreichbar. need_kubeconfig und need_tenant stoppen das Skript frühzeitig,
# wenn Zugriff oder Tenant-Nummer nicht gesetzt sind, — sonst würden alle Prüfungen auf einmal
# fehlschlagen und man könnte aus dem Bericht den Grund nicht erkennen.
LAB_NAME="07-redis"
LAB_TITLE="Lab 7 · Cache vor einem langsamen Backend"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# Die Namen und Adressen, auf die die gesamte Prüfung schaut, sind an einer Stelle gesammelt:
# man muss sie nicht durch den Skripttext suchen. COZY_KUBECONFIG kann von außen überschrieben
# werden, falls dein Tenant-Zugriff nicht am Standardort liegt.
APP="passes-api"
HR="hr-legacy"
SVC="http://${APP}.default.svc.cluster.local"
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/config}"

# Zwei Abkürzungen für das ganze Skript: kget spricht mit dem Lab-Cluster (dem in KUBECONFIG),
# cozy — mit dem Cozystack-Management-Cluster. Fehlermeldungen werden absichtlich unterdrückt:
# ein fehlendes Objekt ist hier eine normale Situation, die das Skript in eigenen Worten und mit
# einem Hinweis beschreibt, statt mit fremdem Text von kubectl.
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# Ein Feld aus JSON holen. Ohne jq: das gibt es auf einem nackten macOS nicht, python3 aber
# überall dort, wo der Rest der Prüf-Bibliothek funktioniert.
jfield() {
  python3 -c 'import sys,json
try:
    print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))
except Exception:
    pass' "$1" 2>/dev/null
}

# --- managed Redis-Dienst auf dem Management-Cluster -------------------------
# Redis lebt nicht in deinem Lab-Cluster, sondern in einem Tenant auf dem Management-Cluster: es
# ist ein managed Dienst, die Plattform hält ihn selbst am Laufen. Die Rechte im Tenant sind bei
# jedem anders, daher lassen weder eine Zugriffsverweigerung noch ein fehlendes Kubeconfig das Lab
# durchfallen — die Arbeit des Caches wird unten direkt geprüft, mit echten Anfragen, und das ist
# der wahre Beweis.
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "Tenant-Kubeconfig ${COZY_KUBECONFIG} nicht gefunden — Redis-Zustand wurde nicht geprüft" \
       "Pfad angeben: export COZY_KUBECONFIG=~/.kube/config"
else
  REDIS_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get redises.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  REDIS_LIST="$(cozy get redises.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$REDIS_ERR" ]; then
    warn "Redis-Anwendungen im Tenant ${TENANT_NS} konnten nicht angezeigt werden" \
         "deine Tenant-Rolle erlaubt diesen Befehl vielleicht nicht — das ist kein Lab-Fehler; die Arbeit des Caches wird unten direkt geprüft"
  elif [ -z "$REDIS_LIST" ]; then
    fail "im Tenant ${TENANT_NS} gibt es keine einzige Redis-Anwendung" \
         "erstelle sie im Dashboard: Anwendung erstellen -> Redis"
  else
    R_NAME="$(printf '%s' "$REDIS_LIST" | awk 'NR==1{print $1}')"
    R_READY="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    R_REPLICAS="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.spec.replicas}')"
    if [ "$R_READY" = "True" ]; then
      ok "managed Redis „${R_NAME}“ ist bereit, Datenkopien: ${R_REPLICAS:-Standard}"
    else
      warn "Redis „${R_NAME}“ existiert, meldet aber keine Bereitschaft" \
           "sieh dir seinen Zustand im Dashboard an; es kommt in drei bis fünf Minuten hoch"
    fi
    evidence "Redis im Tenant" "$REDIS_LIST"
  fi
fi

# --- das langsame Verzeichnis ist vorhanden und wirklich langsam -------------
# Ohne diese Prüfung bedeutet der Vergleich „vorher und nachher“ nichts: antwortet das Verzeichnis
# sofort, gibt es nichts zu beschleunigen und nichts, was der Cache messen kann.
HR_RUNNING="$(kget pods -l app=hr-legacy --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$HR_RUNNING" -lt 1 ]; then
  fail "Verzeichnis ${HR} läuft nicht" \
       "wende hr-legacy.yaml an und prüfe kubectl describe pod -l app=hr-legacy"
else
  HR_SEC="$(in_cluster_curl "http://${HR}.default.svc.cluster.local/employee?id=1" \
    "-o /dev/null -w %{time_total}")"
  HR_MS="$(python3 -c 'import sys
try: print(int(float(sys.argv[1])*1000))
except Exception: print(-1)' "${HR_SEC:-0}" 2>/dev/null)"
  if [ "${HR_MS:-0}" -ge 300 ] 2>/dev/null; then
    ok "das Verzeichnis antwortet in ${HR_MS} ms — es gibt etwas zu beschleunigen"
    evidence "Verzeichnis-Latenz" "${HR_MS} ms pro /employee-Anfrage"
  elif [ "${HR_MS:-0}" -lt 0 ] 2>/dev/null; then
    fail "Verzeichnis ${HR} hat auf die Anfrage nicht geantwortet" \
         "prüfe kubectl logs -l app=hr-legacy"
  else
    warn "das Verzeichnis antwortet in ${HR_MS} ms, das ist zu schnell für eine Messung" \
         "stelle sicher, dass in hr-legacy.yaml MODE=hr und HR_DELAY=800ms gesetzt sind"
  fi
fi

# --- die Anwendung ist auf den Cache konfiguriert ----------------------------
# Wir parsen die Umgebung des Containers mit Python, nicht mit jsonpath: jsonpath-Filter über
# verschachtelte Listen verhalten sich in verschiedenen kubectl-Versionen unterschiedlich, und
# uns ist wichtig, dass die Prüfung bei allen gleich funktioniert.
DEPLOY_JSON="$(kget deployment "$APP" -o json)"
readenv() {
  printf '%s' "$DEPLOY_JSON" | python3 -c 'import sys,json
try:
    d = json.loads(sys.stdin.read())
    env = d["spec"]["template"]["spec"]["containers"][0].get("env", [])
except Exception:
    raise SystemExit
want = sys.argv[1]
if want == "--names":
    print("\n".join(e.get("name","") for e in env))
else:
    for e in env:
        if e.get("name") == want:
            print(e.get("value", ""))
            break' "$1" 2>/dev/null
}

ENVS="$(readenv --names)"
REDIS_ADDR="$(readenv REDIS_ADDR)"
TTL="$(readenv CACHE_TTL)"

# Die Beanstandungen werden der Reihe nach abgearbeitet — von der allgemeinsten zur speziellsten:
# keine Anwendung, keine Variable, ein Platzhalter statt einer Adresse. Die Reihenfolge ist hier
# nicht kosmetisch: sonst bekäme ein Teilnehmer den Rat „trage die Redis-Adresse ein“ in einem
# Moment, in dem der Dienst selbst noch nicht ausgerollt ist, und würde den Fehler an der falschen
# Stelle suchen.
if [ -z "$(kget deployment "$APP" -o name)" ]; then
  fail "der Lab-Cluster hat keine Anwendung ${APP}" \
       "wende passes-api.yaml an und trage deine Harbor-Adresse ein"
elif [ -z "$REDIS_ADDR" ]; then
  fail "in ${APP} ist die Variable REDIS_ADDR nicht gesetzt — der Cache ist aus" \
       "wende den Patch an: kubectl patch deployment ${APP} --patch-file cache-patch.yaml"
elif printf '%s' "$REDIS_ADDR" | grep -q 'REDIS-ADDR'; then
  fail "im Patch steht noch die Platzhalter-Adresse REDIS-ADDR" \
       "trage deine Redis-Adresse ein, zum Beispiel rfrm-redis-cache.${TENANT_NS}.svc.cozy.local"
else
  ok "die Anwendung ist auf den Cache unter ${REDIS_ADDR} konfiguriert, Eintragslebensdauer ${TTL:-Standard} s"
fi

# Wir schauen nur, ob der Variablenname vorhanden ist, wir lesen oder drucken seinen Wert nirgends.
# Den Lab-Bericht leiten die Leute einander weiter und hängen ihn an Tickets — ein dort gelandetes
# Passwort bleibt für immer dort.
if printf '%s' "$ENVS" | grep -q '^REDIS_PASSWORD$'; then
  ok "das Redis-Passwort erreicht die Anwendung (Wert: <verborgen>)"
else
  fail "in ${APP} ist die Variable REDIS_PASSWORD nicht gesetzt" \
       "Redis verlangt Authentifizierung; erstelle das Secret redis-password und wende cache-patch.yaml an"
fi

# Ein fehlendes Secret ist eine Warnung, kein Fehlschlag: das Passwort kann dem Pod auch anders
# zugestellt werden. Die hier geprüfte Eigenschaft ist eine andere — im Manifest liegt ein Verweis,
# kein Wert.
if [ -n "$(kget secret redis-password -o name)" ]; then
  ok "das Secret redis-password mit dem Redis-Passwort existiert"
else
  warn "im Cluster gibt es kein Secret redis-password" \
       "erstelle es: read -rs P && kubectl create secret generic redis-password --from-literal=password=\"\$P\""
fi

# --- die Hauptprüfung: der Cache beschleunigt wirklich -----------------------
# Wir nehmen einen bewusst neuen Identifikator, damit die erste Anfrage garantiert ein Miss ist.
PROBE_ID="check$$$RANDOM"
R1="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"
R2="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"

C1="$(printf '%s' "$R1" | jfield cached)"
C2="$(printf '%s' "$R2" | jfield cached)"
T1="$(printf '%s' "$R1" | jfield took_ms)"
T2="$(printf '%s' "$R2" | jfield took_ms)"
MODE="$(printf '%s' "$R2" | jfield cache)"

if [ -z "$C1" ] || [ -z "$C2" ]; then
  fail "Dienst ${APP} hat nicht das erwartete JSON zurückgegeben" \
       "prüfe kubectl logs -l app=passes-api; stelle sicher, dass das Image aus dem app/ dieses Labs gebaut ist (Tag v2)"
  evidence "Was der Dienst geantwortet hat" "erste Anfrage: ${R1:-leer}
zweite Anfrage: ${R2:-leer}"
elif [ "$MODE" != "redis" ]; then
  fail "die Anwendung meldet, dass der Cache aus ist (cache: ${MODE})" \
       "die Variable REDIS_ADDR hat die laufenden Pods nicht erreicht — prüfe kubectl rollout status deployment/${APP}"
elif [ "$C1" = "True" ]; then
  warn "die erste Anfrage kam bereits aus dem Cache — es gibt nichts zu vergleichen" \
       "eine unwahrscheinliche Identifikator-Kollision; führe die Prüfung erneut aus"
elif [ "$C2" != "True" ]; then
  fail "die zweite Anfrage mit demselben Identifikator hat den Cache erneut verfehlt" \
       "die Anwendung kann nicht in Redis schreiben: prüfe kubectl logs -l app=passes-api, üblicherweise steht dort NOAUTH oder ein Timeout"
  evidence "Antworten des Dienstes" "erste:  ${R1}
zweite: ${R2}"
else
  ok "der Cache funktioniert: Miss ${T1} ms, Hit ${T2} ms"
  SPEEDUP="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print(f"{a/b:.0f}" if b > 0 else "mehr als 1000")
except Exception:
    print("?")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  evidence "Messung an einem lebenden Dienst" "Identifikator: ${PROBE_ID}
erste Anfrage (Miss):   ${T1} ms
zweite Anfrage (Hit): ${T2} ms
Gewinn: etwa ${SPEEDUP}x
Eintragslebensdauer: ${TTL:-Standard} s"

  # Der strenge Teil: der Hit muss um eine Größenordnung schneller sein als der Miss. Sonst
  # bedeutet „der Cache funktioniert“ nur, dass der Schlüssel geschrieben wurde, aber es gibt
  # keinen Nutzen.
  FASTER="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print("yes" if a >= 100 and b * 10 <= a else "no")
except Exception:
    print("no")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  if [ "$FASTER" = "yes" ]; then
    ok "der Gewinn ist messbar: der Hit ist etwa ${SPEEDUP}x schneller als der Miss"
  else
    warn "der Cache-Hit bringt keinen spürbaren Gewinn (${T1} ms gegenüber ${T2} ms)" \
         "stelle sicher, dass das Verzeichnis wirklich langsam ist und Redis nicht auf demselben Pod liegt"
  fi
fi

# --- wie viele Kopien des Dienstes sich einen Cache teilen -------------------
# Der Cache ist über alle Kopien geteilt — das ist im Bericht sehenswert: der Hit könnte von einem
# anderen Pod gekommen sein als der Miss, und das ist korrekt.
API_PODS="$(kget pods -l app=passes-api --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$API_PODS" -ge 1 ]; then
  ok "laufende Kopien des Dienstes: ${API_PODS} (sie teilen sich den Cache)"
  evidence "Dienst-Kopien" "$(kget pods -l app=passes-api -o wide)"
else
  fail "keine einzige laufende Kopie von ${APP}" \
       "prüfe kubectl describe pod -l app=passes-api"
fi

finish
