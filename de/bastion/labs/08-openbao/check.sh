#!/usr/bin/env bash
# Prüfung von Lab 8: Das Passwort ist aus dem Manifest in OpenBao ausgelagert und lebt nach Regeln.
#
# Wir prüfen nicht «das Objekt wurde erstellt», sondern das Wesentliche: Der Tresor ist entsiegelt,
# das Secret ist per Token lesbar, es gibt mehr als eine Version (das heißt, eine Rotation hat
# tatsächlich stattgefunden), das Audit ist aktiviert, und im angewendeten Anwendungsmanifest gibt es
# keine Klartext-Passwörter.
#
# Kein einziges Secret landet im Bericht. Werte werden nirgendwo ausgegeben.
#
# Das Skript startet Wegwerf-Pods mit curl, deshalb läuft es etwa eine Minute.

# LAB_NAME und LAB_TITLE gehen in den Berichtskopf. Weiter unten wird die gemeinsame Prüf-Bibliothek
# eingebunden: aus ihr stammen ok / warn / fail / evidence / finish und die Funktionen, die
# Wegwerf-Pods im Cluster starten. need_kubeconfig und need_tenant stoppen das Skript frühzeitig,
# wenn Zugriff oder die Tenant-Nummer nicht gesetzt sind: sonst würde alles auf einmal fehlschlagen
# und aus dem Bericht ließe sich die Ursache nicht ablesen.
LAB_NAME="08-openbao"
LAB_TITLE="Lab 8 · Secrets nicht im Manifest"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# --- wohin schauen ---------------------------------------------------------
# COZY_TENANT gibt der Teilnehmer als `workshop07` an, aber der Namespace heißt
# `tenant-workshop07`. Wir akzeptieren beide Schreibweisen: hier vertut man sich leicht, und die
# Fehlermeldung wäre kryptisch («Dienst antwortet nicht»).
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# Was und wo wir suchen. BAO_APP ist der Name der OpenBao-Anwendung im Tenant, und er ist Teil der
# internen Adresse des Tresors: haben Sie die Anwendung anders benannt, starten Sie die Prüfung
# als BAO_APP=name ./check.sh. SECRET_PATH ist der Pfad innerhalb des Tresors, unter dem die Lab
# das Datenbank-Passwort ablegt.
BAO_APP="${BAO_APP:-secrets}"
BAO_URL="http://openbao-${BAO_APP}.${NS}.svc.cozy.local:8200"
APP_DEPLOY="${APP_DEPLOY:-secrets-demo}"
SECRET_PATH="${SECRET_PATH:-passes/db}"

evidence "Tresor-Adresse" "$BAO_URL"

# Einen Wert über eine Schlüsselkette aus JSON auf der Standardeingabe herausziehen.
# Rückgabe 1, wenn der Pfad nicht existiert oder es kein JSON ist — so unterscheidet der Aufrufer
# «kein Schlüssel» von «leerer Wert».
jget() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for k in sys.argv[1:]:
    try:
        d = d[int(k)] if isinstance(d, list) else d[k]
    except Exception:
        sys.exit(1)
print("" if d is None else d)
' "$@" 2>/dev/null
}


# Eine Anfrage an OpenBao. Das Token übergeben wir per Umgebungsvariable aus einem temporären Secret,
# und NICHT als Header in den Argumenten: die Argumente eines Pods sieht jeder mit `get pods`, sie
# liegen in etcd und wandern ins Audit-Log. Hier ist es das Root-Token des Tresors — genau das Leck,
# gegen das die gesamte Lab geschrieben ist.
#
# Die Definition steht VOR dem ersten Aufruf: als sie im else-Zweig lag, rief die allererste Prüfung
# eine nicht existierende Funktion auf und die Lab konnte niemals bestehen.
bao_get() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "BAO_TOKEN=${BAO_TOKEN:-}
BAO_URL=${BAO_URL}
BAO_PATH=$1" \
    sh -c 'curl -s --max-time 15 -H "X-Vault-Token: $BAO_TOKEN" "$BAO_URL$BAO_PATH"'
}

# --- 1. der Tresor antwortet -----------------------------------------------
# Schon die erste Anfrage beantwortet zwei Fragen auf einmal: ist die Anwendung hochgekommen und ist
# die Tenant-Nummer richtig angegeben. Wir fragen den Siegel-Status ab — das ist der einzige Endpunkt,
# den OpenBao ohne Token liefert. Eine leere Antwort weiter unten bedeutet «keine Verbindung», und alle
# Inhaltsprüfungen verlieren ihren Sinn.
SEAL="$(bao_get "/v1/sys/seal-status")"

if [ -z "$SEAL" ]; then
  fail "OpenBao antwortet nicht unter ${BAO_URL}" \
       "prüfen Sie die Tenant-Nummer in COZY_TENANT und den Anwendungsnamen (standardmäßig 'secrets'; sonst BAO_APP=name ./check.sh); im Dashboard muss die Anwendung im bereiten Zustand sein"
else
  ok "OpenBao antwortet unter der internen Adresse des Tenants"
fi

# --- 2. initialisiert ------------------------------------------------------
# Die Initialisierung ist ein einmaliger Vorgang, bei dem der Tresor sich seinen Master-Key
# und das erste Token erzeugt. Solange sie nicht erfolgt ist, ist innen nichts: keine Secrets, kein Platz dafür.
INITED="$(printf '%s' "$SEAL" | jget initialized)"
if [ "$INITED" = "True" ]; then
  ok "Tresor ist initialisiert"
elif [ -n "$SEAL" ]; then
  fail "Tresor ist nicht initialisiert" \
       "führen Sie aus: kubectl exec bao-workbench -- bao operator init -key-shares=1 -key-threshold=1 und speichern Sie die Ausgabe"
fi

# --- 3. entsiegelt ---------------------------------------------------------
# Ein versiegelter Tresor ist der normale Zustand nach einem Pod-Neustart: die Daten liegen auf der
# Platte, aber es gibt nichts, um sie zu lesen, bis der Unseal-Key eingegeben ist. Daher die Anforderung,
# das Verhalten zu prüfen und nicht das Vorhandensein eines Objekts: «Anwendung bereit» und «Secrets werden
# ausgeliefert» sind zwei verschiedene Aussagen, und die zweite folgt nicht aus der ersten.
SEALED="$(printf '%s' "$SEAL" | jget sealed)"
if [ "$SEALED" = "False" ]; then
  ok "Tresor ist entsiegelt und bedient Anfragen"
  evidence "Tresor-Zustand" "$SEAL"
elif [ -n "$SEAL" ]; then
  fail "Tresor ist versiegelt — auf jede Anfrage antwortet er mit einer 503-Ablehnung" \
       "führen Sie aus: kubectl exec bao-workbench -- bao operator unseal <Ihr-Unseal-Key>"
  evidence "Tresor-Zustand" "$SEAL"
fi

# --- 4. das Secret ist vorhanden und wird gelesen --------------------------
# Als Nächstes braucht es ein Token. Ohne es gibt es nichts zu prüfen, aber stillschweigend überspringen
# darf man auch nicht: der Leser muss sehen, was fehlt.
if [ -z "$SEAL" ]; then
  # Keine Verbindung — den Inhalt zu prüfen ist sinnlos. Wir schweigen, um den Bericht nicht mit vier
  # Fehlschlägen zu überfluten, die alle dieselbe, oben genannte Ursache haben.
  warn "Tresor-Inhalt nicht geprüft: keine Verbindung zu OpenBao" \
       "klären Sie die Verbindung, dann starten Sie das Skript erneut"
elif [ -z "${BAO_TOKEN:-}" ]; then
  fail "die Variable BAO_TOKEN ist nicht gesetzt, deshalb wurde der Tresor-Inhalt nicht geprüft" \
       "export BAO_TOKEN='das Root-Token, das beim ersten Entsiegeln des Tresors ausgegeben wurde' und starten Sie das Skript erneut"
else

  DATA="$(bao_get "/v1/secret/data/${SECRET_PATH}")"
  PASS_PRESENT="$(printf '%s' "$DATA" | jget data data password)"
  DATA_VERSION="$(printf '%s' "$DATA" | jget data metadata version)"

  if [ -n "$PASS_PRESENT" ]; then
    ok "Secret secret/${SECRET_PATH} ist per Token lesbar, das Feld password ist nicht leer"
    # In den Bericht legen wir die Versionsnummer, nicht den Wert.
    evidence "Secret" "Pfad: secret/${SECRET_PATH}
Feld password: vorhanden (Wert verborgen)
aktuelle Version: ${DATA_VERSION:-unbekannt}"
  else
    fail "unter secret/${SECRET_PATH} gibt es kein Feld password" \
         "legen Sie es ab: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=... ; falls die Engine noch nicht aktiviert ist — bao secrets enable -path=secret kv-v2"
  fi

  # --- 5. die Rotation hat tatsächlich stattgefunden ----------------------
  # Eine einzige Version eines Secrets bedeutet, dass es abgelegt und vergessen wurde. Die Rotation ist
  # das, wofür man einen Tresor überhaupt einrichtet: das Passwort an einer Stelle ändern, statt es
  # durch die Manifeste zu suchen. Wir zählen nicht Versprechen, sondern Versionen: deren Zählung führt der Tresor selbst.
  META="$(bao_get "/v1/secret/metadata/${SECRET_PATH}")"
  CUR_VER="$(printf '%s' "$META" | jget data current_version)"
  case "$CUR_VER" in
    ''|*[!0-9]*) CUR_VER=0 ;;
  esac
  if [ "$CUR_VER" -ge 2 ]; then
    ok "das Secret wurde geändert: ${CUR_VER} Versionen, also fand die Rotation nicht nur in Worten statt"
    evidence "Versionsverlauf des Secrets" "$(printf '%s' "$META" | jget data versions)"
  else
    fail "das Secret hat nur eine Version — die Rotation wurde nicht durchgeführt" \
         "ändern Sie das Passwort: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=<neu> und starten Sie die Anwendung neu"
  fi

  # --- 6. die Policy ist eng, nicht «alles erlaubt» ------------------------
  # Die Policy ist die Antwort auf die Frage «was kann jemand tun, der das Token erlangt hat». Deshalb
  # schauen wir nicht auf die Tatsache ihrer Existenz, sondern auf ihren Inhalt: ist sie auf einen konkreten
  # Pfad statt auf den gesamten Tresor ausgestellt und nur auf Lesen.
  POL="$(bao_get "/v1/sys/policies/acl/passes-read")"
  POL_BODY="$(printf '%s' "$POL" | jget data policy)"
  if [ -n "$POL_BODY" ]; then
    ok "die Policy passes-read existiert"
    evidence "Policy passes-read" "$POL_BODY"
    if printf '%s' "$POL_BODY" | grep -q 'secret/data/'"${SECRET_PATH}"; then
      ok "die Policy ist auf einen konkreten Pfad ausgestellt, nicht auf den gesamten Tresor"
    else
      warn "die Policy existiert, aber der Pfad secret/data/${SECRET_PATH} ist darin nicht zu sehen" \
           "prüfen Sie, dass in der Policy das Präfix data angegeben ist: secret/data/${SECRET_PATH}"
    fi
    if printf '%s' "$POL_BODY" | grep -Eq '"(create|update|delete|sudo)"'; then
      warn "die Policy erlaubt nicht nur Lesen" \
           "der Anwendung genügt read; überflüssige Rechte sollten entfernt werden"
    fi
  else
    fail "die Policy passes-read wurde nicht gefunden" \
         "erstellen Sie sie: kubectl exec -i bao-workbench -- bao policy write passes-read - < Ihre Policy-Datei (Erläuterung der Policy — in der README)"
  fi

  # --- 7. Audit ist aktiviert ----------------------------------------------
  # Ohne Audit-Log gibt es nichts, womit man die Frage «wer und wann hat dieses Secret gelesen» beantworten
  # könnte — und das ist die erste Frage, die nach einem Vorfall gestellt wird. Wir zählen die angebundenen
  # Audit-Geräte: mindestens eines muss vorhanden sein.
  AUD="$(bao_get "/v1/sys/audit")"
  AUD_COUNT="$(printf '%s' "$AUD" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
data = d.get("data", d)
print(len([k for k in data if isinstance(data.get(k), dict)]))
' 2>/dev/null)"
  case "$AUD_COUNT" in
    ''|*[!0-9]*) AUD_COUNT=0 ;;
  esac
  if [ "$AUD_COUNT" -ge 1 ]; then
    ok "Audit-Log ist aktiviert (Geräte: ${AUD_COUNT})"
    evidence "Audit-Geräte" "$AUD"
  else
    fail "Audit-Log ist nicht aktiviert — es gibt nichts, womit man beantworten könnte, wer das Secret gelesen hat" \
         "aktivieren Sie es: kubectl exec bao-workbench -- bao audit enable file file_path=stdout"
  fi
fi

# --- 8. die Anwendung im Lab-Cluster ---------------------------------------
# Bis hierher haben wir den Tresor auf dem Management-Cluster geprüft. Weiter geht es mit Ihrem Lab-Cluster,
# wo die Anwendung selbst lebt. Wichtig ist hier nicht die Tatsache, dass das Deployment erstellt wurde, sondern
# das Vorhandensein bereiter Kopien: ein Init-Container, der das Passwort nicht abholen konnte, lässt den Pod
# nicht hochkommen, und genau diesen Zustand muss man von «alles gut» unterscheiden.
if ! kubectl get deploy "$APP_DEPLOY" >/dev/null 2>&1; then
  fail "im Lab-Cluster gibt es keine Anwendung ${APP_DEPLOY}" \
       "wenden Sie an: kubectl apply -f secrets-demo.yaml (vergessen Sie nicht, Ihre Tenant-Nummer einzusetzen)"
else
  READY="$(kubectl get deploy "$APP_DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  case "$READY" in
    ''|*[!0-9]*) READY=0 ;;
  esac
  if [ "$READY" -ge 1 ]; then
    ok "Anwendung ${APP_DEPLOY} läuft (bereite Kopien: ${READY})"
  else
    fail "Anwendung ${APP_DEPLOY} existiert, aber keine Kopie ist bereit" \
         "sehen Sie sich kubectl describe deploy/${APP_DEPLOY} und kubectl logs deploy/${APP_DEPLOY} -c fetch-secret an — meist konnte der Init-Container den Tresor nicht erreichen oder wurde per Token abgewiesen"
  fi

  # --- 9. keine Klartext-Passwörter im Manifest ----------------------------
  # Wir betrachten das angewendete Objekt, nicht die Datei auf der Platte: angewendet werden konnte alles Mögliche.
  LEAKS="$(kubectl get deploy "$APP_DEPLOY" -o json 2>/dev/null | python3 -c '
import sys, json, re
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
suspicious = re.compile(r"(?i)pass|secret|token|key|cred")
spec = d.get("spec", {}).get("template", {}).get("spec", {})
found = []
for c in list(spec.get("initContainers", [])) + list(spec.get("containers", [])):
    for e in c.get("env", []):
        if "value" in e and suspicious.search(e.get("name", "")):
            found.append("%s / env %s ist per Wert gesetzt, nicht per Referenz" % (c.get("name"), e.get("name")))
print("\n".join(found))
' 2>/dev/null)"

  if [ -z "$LEAKS" ]; then
    ok "im Anwendungsmanifest gibt es keine Variablen mit einem per Wert gesetzten Passwort"
  else
    fail "im Anwendungsmanifest sind noch sensible Werte im Klartext geblieben" \
         "entfernen Sie sie: der Wert muss aus dem Tresor kommen, und im Manifest — nur eine Referenz. Siehe secrets-demo.yaml"
    evidence "Was im Manifest gefunden wurde" "$LEAKS"
  fi

  # --- 10. die Anwendung hat das Secret tatsächlich erhalten ---------------
  # Den letzten Beweis holen wir aus den Logs, nicht aus der Objektbeschreibung. Das Manifest kann
  # makellos sein, während das Passwort nie im Pod ankommt. Wir schauen auf zwei Dinge zugleich:
  # der Init-Container hat gemeldet, dass er zum Tresor gegangen ist, und die Anwendung gibt einen Fingerabdruck aus —
  # das heißt, sie arbeitet tatsächlich mit dem erhaltenen Passwort.
  INIT_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c fetch-secret --tail=5 2>/dev/null)"
  if printf '%s' "$INIT_LOG" | grep -qi 'openbao'; then
    ok "der Init-Container hat das Secret aus dem Tresor geholt"
    evidence "Log des Init-Containers" "$INIT_LOG"
  else
    fail "es ist nicht zu sehen, dass der Init-Container das Secret aus dem Tresor geholt hat" \
         "prüfen Sie kubectl logs deploy/${APP_DEPLOY} -c fetch-secret; wenn es den Container nicht gibt — es wurde ein altes Manifest angewendet"
  fi

  APP_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c app --tail=3 2>/dev/null)"
  if printf '%s' "$APP_LOG" | grep -q 'sha256:'; then
    ok "die Anwendung arbeitet mit dem erhaltenen Passwort (ins Log wird ein Fingerabdruck geschrieben, nicht der Wert)"
    evidence "Log der Anwendung" "$APP_LOG"
  else
    fail "im Log der Anwendung gibt es keinen Passwort-Fingerabdruck" \
         "prüfen Sie kubectl logs deploy/${APP_DEPLOY} -c app — der Container konnte womöglich nicht starten"
  fi
fi

# --- 11. das naive Secret ist entfernt -------------------------------------
# Wir werten es nur dann als «entfernt», wenn die Lab überhaupt gemacht wurde: auf einem sauberen Cluster
# gab es das Secret nie, und der Bericht würde den Teilnehmer für ein Aufräumen loben, das nie stattfand.
if kubectl get secret passes-db >/dev/null 2>&1; then
  warn "im Cluster ist noch das Secret passes-db aus der naiven Stufe geblieben" \
       "es wird nicht mehr benötigt und enthält das alte Passwort: kubectl delete secret passes-db"
elif kubectl get deployment secrets-demo >/dev/null 2>&1; then
  ok "das naive Secret passes-db wurde entfernt"
fi

finish
