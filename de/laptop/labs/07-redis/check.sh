#!/usr/bin/env bash
# Prüfung für Lab 7: der Cache beschleunigt wirklich, und die Zahlen zeigen es.
#
# Die Hauptprüfung ist hier verhaltensbasiert, nicht strukturell. Das Skript wählt selbst einen
# ungenutzten Bezeichner, fragt ihn zweimal ab und beobachtet: das erste Mal muss ein Fehltreffer von
# Hunderten Millisekunden sein, das zweite — ein Treffer im einstelligen Bereich. Ein Manifest mit den
# richtigen Umgebungsvariablen besteht diese Prüfung nicht, wenn der Cache nicht wirklich antwortet.
#
# Zwei Cluster: KUBECONFIG — dein Lab-Cluster, COZY_KUBECONFIG — der Cozystack-
# Management-Cluster, auf dem der managed Redis-Dienst lebt.

# LAB_NAME und LAB_TITLE gehen in den Berichtskopf. Danach wird die gemeinsame Prüfbibliothek
# eingebunden: aus ihr kommen ok / warn / fail / evidence / finish und, am wichtigsten,
# in_cluster_curl — sie startet einen einmaligen Pod mit curl INNERHALB des Clusters. Von innen,
# nicht vom Laptop: die Lab-Dienste sind nicht nach außen freigegeben, und passes-api ist per
# Name nur aus dem Cluster erreichbar. need_kubeconfig und need_tenant stoppen das Skript früh,
# falls Zugriff oder Tenant-Nummer nicht gesetzt sind — sonst würden alle Prüfungen auf einmal
# fehlschlagen und der Bericht würde die Ursache nicht offenbaren.
LAB_NAME="07-redis"
LAB_TITLE="Lab 7 · Cache vor einem langsamen Backend"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# Die Namen und Adressen, auf die die ganze Prüfung schaut, sind an einer Stelle gesammelt: man muss
# sie nicht durch den Skripttext suchen. COZY_KUBECONFIG kann von außen überschrieben werden,
# falls dein Tenant-Zugriff woanders als am Standardort liegt.
APP="passes-api"
HR="hr-legacy"
SVC="http://${APP}.default.svc.cluster.local"
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/workshop}"

# Zwei Kürzel für das ganze Skript: kget spricht mit dem Lab-Cluster (dem in KUBECONFIG),
# cozy — mit dem Cozystack-Management-Cluster. Fehlermeldungen werden absichtlich unterdrückt:
# ein fehlendes Objekt ist hier eine normale Situation, die das Skript mit eigenen Worten
# und mit einem Hinweis erklärt, statt mit fremdem Text von kubectl.
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# Ein Feld aus JSON holen. Ohne jq: es ist auf einem nackten macOS nicht vorhanden, aber python3 ist
# überall dort, wo der Rest der Prüfbibliothek funktioniert.
jfield() {
  python3 -c 'import sys,json
try:
    print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))
except Exception:
    pass' "$1" 2>/dev/null
}

# --- managed Redis-Dienst auf dem Management-Cluster -------------------------
# Redis lebt nicht in deinem Lab-Cluster, sondern in einem Tenant auf dem Management-Cluster: es ist
# ein managed Dienst, die Plattform hält ihn selbst am Laufen. Die Rechte im Tenant sind bei jedem
# anders, daher lässt weder eine Zugriffsverweigerung noch ein fehlendes Kubeconfig das Lab
# durchfallen — dass der Cache funktioniert, wird unten direkt mit Live-Anfragen geprüft, und das ist
# der echte Beweis.
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "Tenant-Kubeconfig ${COZY_KUBECONFIG} nicht gefunden — Redis-Zustand wurde nicht geprüft" \
       "gib den Pfad an: export COZY_KUBECONFIG=~/.kube/workshop"
else
  REDIS_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get redises.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  REDIS_LIST="$(cozy get redises.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$REDIS_ERR" ]; then
    warn "Redis-Anwendungen im Tenant ${TENANT_NS} konnten nicht angezeigt werden" \
         "deine Tenant-Rolle erlaubt diesen Befehl möglicherweise nicht — das ist kein Lab-Fehler; der Cache wird unten direkt geprüft"
  elif [ -z "$REDIS_LIST" ]; then
    fail "Tenant ${TENANT_NS} hat keine Redis-Anwendungen" \
         "erstelle eine im Dashboard: Anwendung erstellen -> Redis"
  else
    R_NAME="$(printf '%s' "$REDIS_LIST" | awk 'NR==1{print $1}')"
    R_READY="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    R_REPLICAS="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.spec.replicas}')"
    if [ "$R_READY" = "True" ]; then
      ok "managed Redis «${R_NAME}» ist bereit, Datenkopien: ${R_REPLICAS:-Standard}"
    else
      warn "Redis «${R_NAME}» existiert, meldet aber keine Bereitschaft" \
           "prüfe seinen Zustand im Dashboard; es kommt in drei bis fünf Minuten hoch"
    fi
    evidence "Redis im Tenant" "$REDIS_LIST"
  fi
fi

# --- das langsame Verzeichnis ist vorhanden und tatsächlich langsam ----------
# Ohne diese Prüfung bedeutet der Vergleich «vorher und nachher» nichts: wenn das Verzeichnis
# sofort antwortet, gibt es nichts zu beschleunigen und nichts, was der Cache messen könnte.
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
    warn "das Verzeichnis antwortet in ${HR_MS} ms, das ist zu schnell zum Messen" \
         "stelle sicher, dass hr-legacy.yaml MODE=hr und HR_DELAY=800ms setzt"
  fi
fi

# --- die Anwendung ist für den Cache konfiguriert ----------------------------
# Wir parsen die Container-Umgebung mit python, nicht mit jsonpath: jsonpath-Filter über
# verschachtelte Listen verhalten sich in verschiedenen kubectl-Versionen unterschiedlich, und wir
# wollen, dass die Prüfung bei allen gleich funktioniert.
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

# Die Beschwerden werden der Reihe nach behandelt — von der allgemeinsten zur speziellsten: keine
# Anwendung, keine Variable, ein Platzhalter statt der Adresse übrig geblieben. Die Reihenfolge ist
# hier nicht kosmetisch: sonst bekäme der Teilnehmer den Rat «trage die Redis-Adresse ein» in einem
# Moment, in dem der Dienst selbst noch nicht deployt ist, und würde den Fehler an der falschen
# Stelle suchen.
if [ -z "$(kget deployment "$APP" -o name)" ]; then
  fail "der Lab-Cluster hat keine Anwendung ${APP}" \
       "wende passes-api.yaml an und trage deine eigene Harbor-Adresse ein"
elif [ -z "$REDIS_ADDR" ]; then
  fail "die Variable REDIS_ADDR ist in ${APP} nicht gesetzt — der Cache ist aus" \
       "wende den Patch an: kubectl patch deployment ${APP} --patch-file cache-patch.yaml"
elif printf '%s' "$REDIS_ADDR" | grep -q 'REDIS-ADDR'; then
  fail "die Platzhalter-Adresse REDIS-ADDR steht noch im Patch" \
       "trage deine eigene Redis-Adresse ein, zum Beispiel rfrm-redis-cache.${TENANT_NS}.svc.cozy.local"
else
  ok "die Anwendung ist für den Cache unter ${REDIS_ADDR} konfiguriert, Eintragslebensdauer ${TTL:-Standard} s"
fi

# Wir schauen nur, ob der Variablenname vorhanden ist, wir lesen oder drucken seinen Wert nirgendwo.
# Menschen leiten den Lab-Bericht aneinander weiter und hängen ihn an Tickets an — ein Passwort,
# das dort landet, bliebe dort für immer.
if printf '%s' "$ENVS" | grep -q '^REDIS_PASSWORD$'; then
  ok "das Redis-Passwort erreicht die Anwendung (Wert: <verborgen>)"
else
  fail "die Variable REDIS_PASSWORD ist in ${APP} nicht gesetzt" \
       "Redis erfordert Authentifizierung; erstelle das Secret redis-password und wende cache-patch.yaml an"
fi

# Ein fehlendes Secret ist eine Warnung, kein Fehlschlag: das Passwort kann auf andere Weise an den
# Pod geliefert werden. Die hier geprüfte Eigenschaft ist eine andere — das Manifest hält eine
# Referenz, keinen Wert.
if [ -n "$(kget secret redis-password -o name)" ]; then
  ok "das Secret redis-password mit dem Redis-Passwort existiert"
else
  warn "der Cluster hat kein Secret redis-password" \
       "erstelle es: read -rs P && kubectl create secret generic redis-password --from-literal=password=\"\$P\""
fi

# --- die Hauptprüfung: der Cache beschleunigt tatsächlich --------------------
# Wir wählen einen bewusst neuen Bezeichner, damit die erste Anfrage garantiert ein Fehltreffer ist.
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
  warn "die erste Anfrage kam bereits aus dem Cache — nichts zum Vergleichen" \
       "eine unwahrscheinliche Bezeichner-Kollision; führe die Prüfung erneut aus"
elif [ "$C2" != "True" ]; then
  fail "die zweite Anfrage nach demselben Bezeichner hat den Cache erneut verfehlt" \
       "die Anwendung kann nicht in Redis schreiben: prüfe kubectl logs -l app=passes-api, meist NOAUTH oder ein Timeout dort"
  evidence "Dienst-Antworten" "erste:  ${R1}
zweite: ${R2}"
else
  ok "der Cache funktioniert: Fehltreffer ${T1} ms, Treffer ${T2} ms"
  SPEEDUP="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print(f"{a/b:.0f}" if b > 0 else "mehr als 1000")
except Exception:
    print("?")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  evidence "Messung an einem Live-Dienst" "Bezeichner: ${PROBE_ID}
erste Anfrage (Fehltreffer):   ${T1} ms
zweite Anfrage (Treffer): ${T2} ms
Gewinn: etwa ${SPEEDUP}x
Eintragslebensdauer: ${TTL:-Standard} s"

  # Der strenge Teil: der Treffer muss eine Größenordnung schneller sein als der Fehltreffer. Sonst
  # bedeutet «der Cache funktioniert» nur, dass der Schlüssel geschrieben wurde, aber es gibt keinen Nutzen.
  FASTER="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print("yes" if a >= 100 and b * 10 <= a else "no")
except Exception:
    print("no")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  if [ "$FASTER" = "yes" ]; then
    ok "der Gewinn ist messbar: der Treffer ist etwa ${SPEEDUP}x schneller als der Fehltreffer"
  else
    warn "der Cache-Treffer bringt keinen merklichen Gewinn (${T1} ms gegen ${T2} ms)" \
         "stelle sicher, dass das Verzeichnis tatsächlich langsam ist und dass Redis nicht auf demselben Pod läuft"
  fi
fi

# --- wie viele Kopien des Dienstes sich einen Cache teilen -------------------
# Der Cache ist über alle Kopien geteilt — das ist es wert, im Bericht zu sehen: der Treffer könnte
# von einem anderen Pod gekommen sein als der Fehltreffer, und das ist korrekt.
API_PODS="$(kget pods -l app=passes-api --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$API_PODS" -ge 1 ]; then
  ok "laufende Dienst-Kopien: ${API_PODS} (sie teilen sich den Cache)"
  evidence "Dienst-Kopien" "$(kget pods -l app=passes-api -o wide)"
else
  fail "keine einzige laufende Kopie von ${APP}" \
       "prüfe kubectl describe pod -l app=passes-api"
fi

finish
