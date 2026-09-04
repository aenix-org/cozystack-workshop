#!/usr/bin/env bash
# Prüfung von Labor 6: Die Anwendung wird aus IHRER EIGENEN privaten Registry in den Cluster geholt.
#
# Wir prüfen nicht «Harbor wurde erstellt», sondern die ganze Kette: Die Registry antwortet über ihre API,
# das Image im Manifest liegt genau in ihr, der Cluster hat Zugangsdaten für dieselbe Adresse,
# und ein Pod mit diesem Image läuft und antwortet tatsächlich.
#
# Zwei Cluster, und das ist der Hauptgrund, warum das Skript komplexer aussieht als die benachbarten:
# KUBECONFIG ist Ihr lab-Cluster, in dem die Anwendung läuft; COZY_KUBECONFIG ist der
# Cozystack-Management-Cluster, in dem in Ihrem Tenant der managed-Dienst Harbor lebt.
# Mit einem Befehl lassen sie sich nicht abfragen, deshalb gibt es unten zwei verschiedene Wege, kubectl aufzurufen.
#
# Wird von Ihnen ausgeführt, aus dem Labor-Ordner; ändert nichts, schaut nur und gibt einen Bericht aus:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_KUBECONFIG=~/.kube/workshop
#     ./check.sh

LAB_NAME="06-harbor"
LAB_TITLE="Labor 6 · Eigene private Image-Registry"
# Gemeinsame Umgebung aller Labore: ok / fail / warn / evidence / finish und Umgebungsprüfungen.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Ohne Cluster-Zugangsdatei und ohne Tenant-Nummer gibt es nichts zu prüfen — sofort beenden.
need_kubeconfig
need_tenant

APP="passes-api"
# Der Tenant-Namespace auf dem Management-Cluster: Der Name setzt sich aus dem Präfix
# tenant- und Ihrer Nummer zusammen, also tenant-workshopXX. Die Nummer wird aus der Umgebung genommen,
# man muss sie nicht von Hand in den Skripttext einsetzen.
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/workshop}"

# Zwei Wege, kubectl aufzurufen: kget geht in Ihren lab-Cluster, cozy — in den Management-Cluster.
# Fehler werden absichtlich unterdrückt: Ein fehlendes Objekt ist hier kein Absturz, sondern einer der erwarteten
# Ausgänge, und er wird unten in einem eigenen Zweig mit klarem Rat behandelt.
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- managed-Dienst Harbor auf dem Management-Cluster ------------------------
# Optionaler Teil: Ohne den Tenant-Kubeconfig ist das Labor trotzdem prüfbar,
# aber den Dienst von der Plattformseite sehen wir nicht.
#
# Wir fangen gesondert den Fall «Befehl hat nicht funktioniert» ab: Die Rolle im Tenant erlaubt
# möglicherweise nicht, Anwendungen anzusehen. Das ist nicht der Fehler des Teilnehmers und kein Grund, die
# Prüfung durchfallen zu lassen, deshalb hier warn — «nicht angesehen», nicht fail — «falsch gemacht». Befehlsfehler
# und leere Antwort unterscheiden wir absichtlich: Eine leere Liste bedeutet, dass Harbor gar nicht erstellt wurde.
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "Tenant-Kubeconfig ${COZY_KUBECONFIG} nicht gefunden — Harbor-Zustand wurde nicht geprüft" \
       "Pfad angeben: export COZY_KUBECONFIG=~/.kube/workshop"
else
  HARBOR_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get harbors.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  HARBOR_LIST="$(cozy get harbors.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$HARBOR_ERR" ]; then
    warn "Harbor-Anwendungen im Tenant ${TENANT_NS} konnten nicht angesehen werden" \
         "die Rolle im Tenant erlaubt diesen Befehl möglicherweise nicht — das ist kein Laborfehler; alles Übrige wird unten geprüft"
  elif [ -z "$HARBOR_LIST" ]; then
    fail "im Tenant ${TENANT_NS} gibt es keine einzige Harbor-Anwendung" \
         "erstellen Sie sie im Dashboard: Anwendung erstellen -> Harbor"
  else
    HARBOR_NAME="$(printf '%s' "$HARBOR_LIST" | awk 'NR==1{print $1}')"
    HARBOR_READY="$(cozy get harbors.apps.cozystack.io "$HARBOR_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$HARBOR_READY" = "True" ]; then
      ok "managed-Dienst Harbor «${HARBOR_NAME}» ist bereit"
    else
      warn "Harbor «${HARBOR_NAME}» existiert, meldet aber keine Bereitschaft" \
           "schauen Sie sich seinen Zustand im Dashboard an; Harbor startet in 5-10 Minuten und ohne Objektspeicher im Tenant startet er gar nicht"
    fi
    evidence "Harbor-Anwendungen im Tenant" "$HARBOR_LIST"
    # Wir versuchen nicht, das Secret mit den Zugangsdaten zu lesen: Der Tenant kann dieses Secret zwar lesen,
    # aber das Passwort brauchen wir im Bericht ohnehin nicht.
  fi
fi

# --- woher die Anwendung das Image holt --------------------------------------
# Der Sinn des Labors ist, dass das Image aus Ihrer Registry kam, nicht aus dem Internet. Geprüft wird das
# am Image-Namen im Manifest: Der erste Teil des Namens bis zum Schrägstrich ist die Registry-Adresse.
# Enthält er weder Punkt noch Doppelpunkt, ist dort gar keine Adresse, und der Cluster würde stillschweigend
# das Image bei Docker Hub holen — also genau dort, wo es die IT-Sicherheit verboten hat.
# Den Platzhalter HARBOR-HOST und bekannte öffentliche Registries fangen wir in eigenen Zweigen ab:
# formal ist die Adresse vorhanden, die Laboranforderung aber nicht erfüllt, und der Rat ist in jedem Fall ein anderer.
IMAGE="$(kget deployment "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}')"
REGISTRY=""
if [ -z "$IMAGE" ]; then
  fail "im lab-Cluster gibt es keine Anwendung ${APP}" \
       "wenden Sie passes.yaml an, nachdem Sie die Adresse Ihres Harbor eingesetzt haben"
else
  REGISTRY="${IMAGE%%/*}"
  case "$REGISTRY" in
    *.*|*:*) : ;;              # sieht wie eine Registry-Adresse aus
    *) REGISTRY="" ;;          # keine Adresse — also wird das Image von Docker Hub gezogen
  esac

  if [ -z "$REGISTRY" ]; then
    fail "Image ${IMAGE} wird aus einer öffentlichen Registry gezogen, nicht aus Ihrer" \
         "im Image-Namen muss als erster Teil die Adresse Ihres Harbor stehen"
  elif printf '%s' "$REGISTRY" | grep -qi 'HARBOR-HOST'; then
    fail "im Manifest ist die Platzhalter-Adresse HARBOR-HOST geblieben" \
         "setzen Sie die Adresse Ihres Harbor ein: sed -i 's|HARBOR-HOST|harbor.ihredomain|g' passes.yaml"
  elif printf '%s' "$REGISTRY" | grep -qiE '^(docker\.io|registry-1\.docker\.io|quay\.io|ghcr\.io|gcr\.io|registry\.k8s\.io)$'; then
    fail "das Image wird aus der öffentlichen Registry ${REGISTRY} gezogen" \
         "die IT-Sicherheit hat eine private Registry verlangt — bauen und pushen Sie das Image in Ihr Harbor"
  else
    ok "die Anwendung startet aus Ihrer Registry: ${REGISTRY}"
    evidence "Image der Anwendung" "$IMAGE"
  fi
fi

# --- die Registry funktioniert tatsächlich -----------------------------------
# Die Adresse im Manifest kann korrekt geschrieben sein, aber unter ihr keine Registry existieren: Harbor
# startet nicht sofort, und ein Tippfehler in der Domain sieht genau gleich aus. Deshalb
# klopfen wir an seine API und warten auf die Antwort «pong» — das bestätigt, dass dort tatsächlich Harbor ist,
# und keine fremde Website und kein Load-Balancer-Stub.
if [ -z "$REGISTRY" ]; then
  : # bereits oben berichtet
elif ! command -v curl >/dev/null 2>&1; then
  warn "kein curl-Werkzeug — Erreichbarkeit der Registry wurde nicht geprüft" \
       "öffnen Sie https://${REGISTRY} im Browser, dort sollte die Harbor-Oberfläche sein"
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
         "prüfen Sie die Adresse und den Zustand der Harbor-Anwendung im Dashboard"
  fi
fi

# --- der Cluster hat Zugangsdaten --------------------------------------------
# Es reicht nicht, dass das Secret im Manifest angegeben ist — wichtig ist, dass es Zugangsdaten genau
# für die Registry hat, aus der das Image gezogen wird. Der häufigste Laborfehler sieht
# korrekt aus: Das Secret ist erstellt, im Manifest benannt, aber die Adresse darin ist falsch
# (überflüssiges https://, ein Port, ein anderer Hostname), und kubelet wendet es nicht an.
# Deshalb entpacken wir den Inhalt des Secrets und vergleichen Adressen, nicht Namen.
PULL_SECRETS="$(kget deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.imagePullSecrets[*]}{.name}{"\n"}{end}')"
if [ -z "$IMAGE" ]; then
  : # keine Anwendung, oben berichtet
elif [ -z "$PULL_SECRETS" ]; then
  fail "im Manifest ${APP} ist kein einziges imagePullSecret angegeben" \
       "ein Image aus einer privaten Registry lädt ohne Zugangsdaten nicht herunter: fügen Sie imagePullSecrets hinzu, siehe passes.yaml"
else
  SECRET_OK=""
  for s in $PULL_SECRETS; do
    STYPE="$(kget secret "$s" -o jsonpath='{.type}')"
    [ "$STYPE" = "kubernetes.io/dockerconfigjson" ] || continue
    # Wir parsen die Konfiguration mit python: base64 -d verhält sich auf macOS und Linux unterschiedlich,
    # und das Passwort darf nicht in den Bericht gedruckt werden — wir nehmen nur die Adressliste.
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

# --- die Pods sind tatsächlich gestartet -------------------------------------
# Wir behandeln die Zustände ImagePullBackOff und ErrImagePull gesondert: Das ist genau der Fehler,
# den das Labor absichtlich zeigt, und dem Teilnehmer ist wichtig, ihn wiederzuerkennen, statt
# ein generisches «Pods funktionieren nicht» zu bekommen. Die echte Ursache drucken wir als Beleg —
# bei einem Registry-Fehler und bei einem Tippfehler im Image-Namen ist der Pod-Zustand derselbe.
PODS="$(kget pods -l app=passes-api --no-headers)"
RUNNING="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BADSTATE="$(printf '%s' "$PODS" | awk '$3!="Running"{print $3}' | sort -u | tr '\n' ' ')"

if [ "$RUNNING" -ge 1 ]; then
  ok "laufende Anwendungs-Replicas: ${RUNNING}"
  evidence "Pods der Anwendung" "$(kget pods -l app=passes-api -o wide)"
elif printf '%s' "$BADSTATE" | grep -q 'ImagePullBackOff\|ErrImagePull'; then
  fail "das Image lädt nicht herunter: ${BADSTATE}" \
       "das ist eine Zugriffsverweigerung auf die Registry oder ein Tippfehler im Image-Namen; die echte Ursache zeigt kubectl describe pod -l app=passes-api"
  evidence "Fehlerursache" "$(kubectl describe pod -l app=passes-api 2>/dev/null \
    | grep -A2 'Failed to pull\|Warning' | head -20)"
else
  fail "es gibt keine einzige laufende Anwendungs-Replica (Zustände: ${BADSTATE:-keine Pods})" \
       "siehe kubectl describe pod -l app=passes-api"
fi

# Eine gesonderte Prüfung für den am schwersten zu diagnostizierenden Laborfehler: Das Image wurde
# für ARM gebaut, während die Cluster-Knoten auf x86 laufen. Alles sieht korrekt aus — das Image wurde gebaut, in die
# Registry gepusht, auf den Knoten heruntergeladen — aber der Prozess startet nicht. Nichts drumherum deutet
# auf die Prozessorarchitektur hin, und der einzige Anhaltspunkt liegt in den Pod-Logs, deshalb
# schauen wir sie mit einer gesonderten Prüfung an und benennen die Ursache direkt.
LOGS="$(kubectl logs -l app=passes-api --tail=20 --all-containers 2>&1)"
if printf '%s' "$LOGS" | grep -q 'exec format error'; then
  fail "das Image wurde für eine andere Prozessorarchitektur gebaut" \
       "bauen Sie neu mit dem Flag: docker build --platform linux/amd64 -t ${IMAGE} app/ und pushen Sie es erneut"
fi

# --- die Anwendung antwortet inhaltlich --------------------------------------
# Ein gestarteter Pod bedeutet noch keinen funktionierenden Dienst. Wir gehen in den Cluster hinein, fragen die
# Anwendung über ihren internen Namen ab und lesen den Pod-Namen aus der Antwort. Stimmt er mit einem tatsächlich
# laufenden überein — dann antwortet genau die Anwendung, die wir bereitgestellt haben, und nicht
# etwas anderes, das zufällig diese Adresse belegt hat. Eine Abweichung ist warn, nicht fail:
# eine Replica konnte zwischen zwei Anfragen neu erstellt worden sein, und daran trifft den Teilnehmer keine Schuld.
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
    fail "der Dienst ${APP} hat nicht das erwartete JSON zurückgegeben" \
         "siehe kubectl logs -l app=passes-api und stellen Sie sicher, dass der Port im Service mit dem Port der Anwendung übereinstimmt"
  elif printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
    ok "der Dienst antwortet mit JSON, die Antwort kam vom tatsächlich laufenden Pod ${SERVED_POD}"
    evidence "Antwort des Dienstes" "$BODY"
  else
    warn "der Dienst antwortete im Namen des Pods ${SERVED_POD}, der nicht unter den laufenden ist" \
         "wahrscheinlich wurde die Replica zwischen den Anfragen neu erstellt — starten Sie die Prüfung erneut"
  fi
fi

finish
