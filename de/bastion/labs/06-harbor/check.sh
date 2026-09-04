#!/usr/bin/env bash
# Prüfung von Lab 6: Die Anwendung gelangt aus IHRER EIGENEN privaten Registry in den Cluster.
#
# Wir prüfen nicht «Harbor ist erstellt», sondern die gesamte Kette: die Registry antwortet über ihre eigene API,
# das Image im Manifest liegt genau dort, der Cluster hat Zugangsdaten für dieselbe Adresse,
# und ein Pod mit diesem Image läuft und antwortet tatsächlich.
#
# Zwei Cluster, und das ist der Hauptgrund, warum das Skript komplexer aussieht als seine Nachbarn:
# KUBECONFIG ist Ihr Lab-Cluster, in dem die Anwendung läuft; COZY_KUBECONFIG ist der
# Cozystack-Management-Cluster, in dem der Managed-Harbor-Dienst in Ihrem Tenant lebt.
# Man kann sie nicht mit einem einzigen Befehl abfragen, daher gibt es unten zwei verschiedene Wege, kubectl aufzurufen.
#
# Von Ihnen ausgeführt, aus dem Lab-Ordner; ändert nichts, schaut nur und gibt einen Bericht aus:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_KUBECONFIG=~/.kube/config
#     ./check.sh

LAB_NAME="06-harbor"
LAB_TITLE="Lab 6 · Ihre eigene private Image-Registry"
# Gemeinsame Umgebung aller Labs: ok / fail / warn / evidence / finish und Umgebungsprüfungen.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Ohne Cluster-Zugangsdatei und ohne Tenant-Nummer gibt es nichts zu prüfen — sofort beenden.
need_kubeconfig
need_tenant

APP="passes-api"
# Der Tenant-Namespace auf dem Management-Cluster: der Name setzt sich aus dem Präfix
# tenant- und Ihrer Nummer zusammen, also tenant-workshopXX. Die Nummer wird aus der Umgebung genommen,
# Sie müssen sie nicht von Hand in den Skripttext einsetzen.
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/config}"

# Zwei Wege, kubectl aufzurufen: kget geht in Ihren Lab-Cluster, cozy — in den Management-Cluster.
# Fehler werden absichtlich unterdrückt: ein fehlendes Objekt ist hier kein Ausfall, sondern einer der erwarteten
# Ausgänge, und er wird unten in einem separaten Zweig mit klarem Rat behandelt.
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- Managed-Harbor-Dienst auf dem Management-Cluster ------------------------
# Optionaler Teil: ohne das Tenant-Kubeconfig ist das Lab trotzdem prüfbar,
# aber wir sehen den Dienst nicht von der Plattformseite.
#
# Wir fangen den Fall «der Befehl hat nicht funktioniert» separat ab: die Rolle im Tenant erlaubt
# möglicherweise nicht, Anwendungen anzusehen. Das ist kein Fehler des Teilnehmers und kein Grund, die Prüfung
# durchfallen zu lassen, daher ist es hier warn — «nicht angesehen», nicht fail — «falsch gemacht». Befehls-
# fehler und leere Antwort unterscheiden wir absichtlich: eine leere Liste bedeutet, dass Harbor gar nicht erstellt wurde.
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "Tenant-Kubeconfig ${COZY_KUBECONFIG} nicht gefunden — Harbor-Status wurde nicht geprüft" \
       "geben Sie den Pfad an: export COZY_KUBECONFIG=~/.kube/config"
else
  HARBOR_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get harbors.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  HARBOR_LIST="$(cozy get harbors.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$HARBOR_ERR" ]; then
    warn "Harbor-Anwendungen im Tenant ${TENANT_NS} konnten nicht angezeigt werden" \
         "die Rolle im Tenant erlaubt diesen Befehl möglicherweise nicht — das ist kein Lab-Fehler; alles andere wird unten geprüft"
  elif [ -z "$HARBOR_LIST" ]; then
    fail "im Tenant ${TENANT_NS} gibt es keine einzige Harbor-Anwendung" \
         "erstellen Sie sie im Dashboard: Anwendung erstellen -> Harbor"
  else
    HARBOR_NAME="$(printf '%s' "$HARBOR_LIST" | awk 'NR==1{print $1}')"
    HARBOR_READY="$(cozy get harbors.apps.cozystack.io "$HARBOR_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$HARBOR_READY" = "True" ]; then
      ok "Managed-Harbor-Dienst «${HARBOR_NAME}» ist bereit"
    else
      warn "Harbor «${HARBOR_NAME}» existiert, meldet aber keine Bereitschaft" \
           "prüfen Sie seinen Status im Dashboard; Harbor braucht 5-10 Minuten zum Hochfahren und fährt ohne Objektspeicher im Tenant überhaupt nicht hoch"
    fi
    evidence "Harbor-Anwendungen im Tenant" "$HARBOR_LIST"
    # Wir versuchen nicht, das Zugangsdaten-Secret zu lesen: der Tenant kann dieses Secret lesen
    # (die Plattform legt für die Zugangsdaten jeder Anwendung eine eigene Regel an),
    # aber wir brauchen das Passwort im Bericht ohnehin nicht.
  fi
fi

# --- woher die Anwendung das Image bezieht ----------------------------------
# Der Sinn des Labs ist, dass das Image aus Ihrer Registry kam, nicht aus dem Internet. Das wird geprüft
# anhand des Image-Namens im Manifest: der erste Teil des Namens bis zum Schrägstrich ist die Registry-Adresse.
# Enthält er weder Punkt noch Doppelpunkt, gibt es dort überhaupt keine Adresse, und der Cluster würde still
# das Image bei Docker Hub holen — also genau dort, wo es das Sicherheitsteam verboten hat.
# Den Platzhalter HARBOR-HOST und bekannte öffentliche Registries fangen wir in separaten Zweigen ab:
# formal ist die Adresse vorhanden, aber die Lab-Anforderung ist nicht erfüllt, und der Rat unterscheidet sich je nach Fall.
IMAGE="$(kget deployment "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}')"
REGISTRY=""
if [ -z "$IMAGE" ]; then
  fail "im Lab-Cluster gibt es keine Anwendung ${APP}" \
       "wenden Sie passes.yaml an und setzen Sie die Adresse Ihres eigenen Harbor ein"
else
  REGISTRY="${IMAGE%%/*}"
  case "$REGISTRY" in
    *.*|*:*) : ;;              # sieht aus wie eine Registry-Adresse
    *) REGISTRY="" ;;          # keine Adresse — das Image wird von Docker Hub geholt
  esac

  if [ -z "$REGISTRY" ]; then
    fail "das Image ${IMAGE} wird aus einer öffentlichen Registry geholt, nicht aus Ihrer" \
         "der erste Teil des Image-Namens muss die Adresse Ihres Harbor sein"
  elif printf '%s' "$REGISTRY" | grep -qi 'HARBOR-HOST'; then
    fail "im Manifest steht noch die Platzhalter-Adresse HARBOR-HOST" \
         "setzen Sie die Adresse Ihres eigenen Harbor ein: sed -i 's|HARBOR-HOST|harbor.ihredomain|g' passes.yaml"
  elif printf '%s' "$REGISTRY" | grep -qiE '^(docker\.io|registry-1\.docker\.io|quay\.io|ghcr\.io|gcr\.io|registry\.k8s\.io)$'; then
    fail "das Image wird aus der öffentlichen Registry ${REGISTRY} geholt" \
         "das Sicherheitsteam hat eine private Registry verlangt — bauen Sie das Image und pushen Sie es in Ihr eigenes Harbor"
  else
    ok "die Anwendung startet aus Ihrer Registry: ${REGISTRY}"
    evidence "Anwendungs-Image" "$IMAGE"
  fi
fi

# --- die Registry funktioniert tatsächlich ----------------------------------
# Die Adresse im Manifest kann korrekt geschrieben sein, aber es gibt möglicherweise keine Registry unter ihr: Harbor
# fährt nicht sofort hoch, und ein Tippfehler in der Domain sieht genauso aus. Deshalb
# klopfen wir an seine API und warten auf die Antwort «pong» — das bestätigt, dass dort tatsächlich Harbor ist,
# und nicht die Website eines anderen oder ein Load-Balancer-Stub.
if [ -z "$REGISTRY" ]; then
  : # bereits oben berichtet
elif ! command -v curl >/dev/null 2>&1; then
  warn "kein curl-Werkzeug — Registry-Erreichbarkeit wurde nicht geprüft" \
       "öffnen Sie https://${REGISTRY} im Browser, dort sollte eine Harbor-Oberfläche sein"
else
  PING="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/ping" 2>/dev/null)"
  if printf '%s' "$PING" | grep -qi 'pong'; then
    VER="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/systeminfo" 2>/dev/null \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("harbor_version","unbekannt"))' 2>/dev/null)"
    ok "die Registry antwortet über die API: https://${REGISTRY} (Harbor ${VER:-Version unbekannt})"
    evidence "Registry" "https://${REGISTRY}
API ping: ${PING}
Harbor-Version: ${VER:-unbekannt}"
  else
    fail "die Registry https://${REGISTRY} antwortet nicht auf die Anfrage /api/v2.0/ping" \
         "prüfen Sie die Adresse und den Status der Harbor-Anwendung im Dashboard"
  fi
fi

# --- der Cluster hat Zugangsdaten -------------------------------------------
# Es reicht nicht, dass das Secret im Manifest referenziert ist — wichtig ist, dass es Zugangsdaten
# für genau die Registry hat, aus der das Image geholt wird. Der häufigste Lab-Fehler sieht
# korrekt aus: das Secret ist erstellt, im Manifest benannt, aber die Adresse darin ist falsch
# (ein überflüssiges https://, ein Port, ein anderer Hostname), und kubelet wendet es nicht an.
# Deshalb entpacken wir den Secret-Inhalt und vergleichen Adressen, nicht Namen.
PULL_SECRETS="$(kget deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.imagePullSecrets[*]}{.name}{"\n"}{end}')"
if [ -z "$IMAGE" ]; then
  : # keine Anwendung, oben berichtet
elif [ -z "$PULL_SECRETS" ]; then
  fail "im Manifest ${APP} ist kein einziges imagePullSecret angegeben" \
       "ein Image aus einer privaten Registry wird ohne Zugangsdaten nicht heruntergeladen: fügen Sie imagePullSecrets hinzu, siehe passes.yaml"
else
  SECRET_OK=""
  for s in $PULL_SECRETS; do
    STYPE="$(kget secret "$s" -o jsonpath='{.type}')"
    [ "$STYPE" = "kubernetes.io/dockerconfigjson" ] || continue
    # Wir parsen die Konfiguration mit Python: base64 -d verhält sich auf macOS und Linux unterschiedlich,
    # und wir dürfen das Passwort nicht in den Bericht drucken — wir nehmen nur die Adressliste.
    SERVERS="$(kget secret "$s" -o jsonpath='{.data.\.dockerconfigjson}' \
      | python3 -c 'import sys,json,base64
raw = sys.stdin.read().strip()
try:
    cfg = json.loads(base64.b64decode(raw))
    print(" ".join(cfg.get("auths", {}).keys()))
except Exception:
    pass' 2>/dev/null)"
    if [ -n "$REGISTRY" ] && printf '%s' "$SERVERS" | grep -q "$REGISTRY"; then
      SECRET_OK="$s"
      break
    fi
  done

  if [ -n "$SECRET_OK" ]; then
    ok "der Cluster hat Zugangsdaten für ${REGISTRY} im Secret ${SECRET_OK} (Passwort: <verborgen>)"
  else
    fail "keines der angegebenen Secrets (${PULL_SECRETS}) enthält Zugangsdaten für ${REGISTRY:-Ihre Registry}" \
         "erstellen Sie es so: kubectl create secret docker-registry harbor --docker-server=${REGISTRY:-ADRESSE} --docker-username=admin --docker-password=..."
  fi
fi

# --- die Pods sind tatsächlich gestartet ------------------------------------
# Wir behandeln die Zustände ImagePullBackOff und ErrImagePull separat: das ist genau der Ausfall,
# den das Lab absichtlich zeigt, und für den Teilnehmer ist es wichtig, ihn auf einen Blick zu erkennen und nicht
# ein allgemeines «die Pods funktionieren nicht» zu bekommen. Die echte Ursache drucken wir als Beleg —
# bei einem Registry-Ausfall und bei einem Tippfehler im Image-Namen ist der Pod-Zustand derselbe.
PODS="$(kget pods -l app=passes-api --no-headers)"
RUNNING="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BADSTATE="$(printf '%s' "$PODS" | awk '$3!="Running"{print $3}' | sort -u | tr '\n' ' ')"

if [ "$RUNNING" -ge 1 ]; then
  ok "laufende Kopien der Anwendung: ${RUNNING}"
  evidence "Anwendungs-Pods" "$(kget pods -l app=passes-api -o wide)"
elif printf '%s' "$BADSTATE" | grep -q 'ImagePullBackOff\|ErrImagePull'; then
  fail "das Image wird nicht heruntergeladen: ${BADSTATE}" \
       "das ist eine verweigerte Registry-Zugriffsberechtigung oder ein Tippfehler im Image-Namen; die echte Ursache zeigt kubectl describe pod -l app=passes-api"
  evidence "Ausfallursache" "$(kubectl describe pod -l app=passes-api 2>/dev/null \
    | grep -A2 'Failed to pull\|Warning' | head -20)"
else
  fail "es gibt keine einzige laufende Kopie der Anwendung (Zustände: ${BADSTATE:-keine Pods})" \
       "siehe kubectl describe pod -l app=passes-api"
fi

# Eine separate Prüfung für den am schwersten zu diagnostizierenden Lab-Fehler: das Image ist für
# ARM gebaut, und die Cluster-Knoten laufen auf x86. Alles sieht korrekt aus — das Image wurde gebaut, ging
# in die Registry, wurde auf den Knoten geladen — aber der Prozess startet nicht. Nichts drumherum deutet
# auf die Prozessorarchitektur hin, und der einzige Anhaltspunkt liegt in den Pod-Logs, deshalb
# schauen wir sie mit einer separaten Prüfung an und benennen die Ursache direkt.
LOGS="$(kubectl logs -l app=passes-api --tail=20 --all-containers 2>&1)"
if printf '%s' "$LOGS" | grep -q 'exec format error'; then
  fail "das Image ist für eine andere Prozessorarchitektur gebaut" \
       "bauen Sie es neu mit dem Flag: docker build --platform linux/amd64 -t ${IMAGE} app/ und pushen Sie erneut"
fi

# --- die Anwendung antwortet inhaltlich -------------------------------------
# Ein gestarteter Pod bedeutet noch keinen funktionierenden Dienst. Wir gehen in den Cluster hinein, fragen
# die Anwendung über ihren internen Namen ab und lesen den Pod-Namen aus der Antwort. Stimmt er mit einem wirklich
# laufenden Pod überein — dann kommt die Antwort von genau der Anwendung, die wir bereitgestellt haben, und nicht
# von etwas anderem, das zufällig diese Adresse belegt hat. Eine Abweichung ist warn, nicht fail:
# eine Kopie könnte zwischen den beiden Anfragen neu erstellt worden sein, und der Teilnehmer trägt daran keine Schuld.
if [ -z "$(kget svc "$APP" -o name)" ]; then
  fail "es gibt keinen Service mit dem Namen ${APP}" \
       "er ist in passes.yaml beschrieben — wenden Sie die ganze Datei an, nicht nur das Deployment"
else
  BODY="$(in_cluster_curl "http://${APP}.default.svc.cluster.local/")"
  SERVED_POD="$(printf '%s' "$BODY" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("pod",""))
except Exception: pass' 2>/dev/null)"

  if [ -z "$SERVED_POD" ]; then
    fail "der Service ${APP} hat nicht das erwartete JSON zurückgegeben" \
         "siehe kubectl logs -l app=passes-api und stellen Sie sicher, dass der Port im Service mit dem Anwendungsport übereinstimmt"
  elif printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
    ok "der Service antwortet mit JSON, die Antwort kam von einem wirklich laufenden Pod ${SERVED_POD}"
    evidence "Service-Antwort" "$BODY"
  else
    warn "der Service antwortete im Namen des Pods ${SERVED_POD}, der nicht unter den laufenden ist" \
         "höchstwahrscheinlich wurde die Kopie zwischen den Anfragen neu erstellt — führen Sie die Prüfung erneut aus"
  fi
fi

finish
