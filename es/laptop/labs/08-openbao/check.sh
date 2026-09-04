#!/usr/bin/env bash
# Comprobación del lab 8: la contraseña se saca del manifiesto a OpenBao y vive según las reglas.
#
# No comprobamos «el objeto se creó», sino la esencia: el almacén está desellado, el secreto se
# lee por token, hay más de una versión (o sea, la rotación de verdad ocurrió), la auditoría
# está activada, y el manifiesto aplicado de la aplicación no tiene contraseñas en texto plano.
#
# Ningún secreto llega al informe. Los valores no se imprimen en ninguna parte.
#
# El script levanta pods de un solo uso con curl, por eso tarda alrededor de un minuto.

# LAB_NAME y LAB_TITLE van al encabezado del informe. Debajo se carga la biblioteca común de
# comprobaciones: de ella se toman ok / warn / fail / evidence / finish y las funciones que
# lanzan pods de un solo uso dentro del clúster. need_kubeconfig y need_tenant detienen el
# script de antemano si no están definidos el acceso o el número de tenant: de lo contrario
# todo fallaría a la vez y por el informe no se podría entender la causa.
LAB_NAME="08-openbao"
LAB_TITLE="Lab 8 · Los secretos fuera del manifiesto"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# --- dónde mirar -----------------------------------------------------------
# El participante define COZY_TENANT como `workshop07`, pero el namespace se llama
# `tenant-workshop07`. Aceptamos ambas grafías: aquí es fácil equivocarse, y el mensaje
# de error sería poco claro («el servicio no responde»).
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# Qué buscamos y dónde. BAO_APP es el nombre de la aplicación OpenBao en el tenant, y forma
# parte de la dirección interna del almacén: si nombraste la aplicación de otra forma, ejecuta
# la comprobación como BAO_APP=nombre ./check.sh. SECRET_PATH es la ruta dentro del almacén
# donde el lab guarda la contraseña de la base de datos.
BAO_APP="${BAO_APP:-secrets}"
BAO_URL="http://openbao-${BAO_APP}.${NS}.svc.cozy.local:8200"
APP_DEPLOY="${APP_DEPLOY:-secrets-demo}"
SECRET_PATH="${SECRET_PATH:-passes/db}"

evidence "Dirección del almacén" "$BAO_URL"

# Extraer un valor por una cadena de claves desde un JSON en la entrada estándar.
# Devuelve 1 si la ruta no existe o no es JSON, para que quien llama pueda distinguir
# «no existe la clave» de «valor vacío».
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


# Una petición a OpenBao. Pasamos el token mediante una variable de entorno desde un Secret
# temporal, y NO como cabecera en los argumentos: los argumentos del pod los ve cualquiera con
# `get pods`, quedan en etcd y acaban en el audit log. Aquí es el token root del almacén: justo
# la fuga contra la que está escrito todo este lab.
#
# La definición va ANTES de la primera llamada: cuando estaba dentro de la rama else, la primera
# comprobación llamaba a una función inexistente y el lab no se aprobaba nunca.
bao_get() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "BAO_TOKEN=${BAO_TOKEN:-}
BAO_URL=${BAO_URL}
BAO_PATH=$1" \
    sh -c 'curl -s --max-time 15 -H "X-Vault-Token: $BAO_TOKEN" "$BAO_URL$BAO_PATH"'
}

# --- 1. el almacén responde ------------------------------------------------
# La primera petición responde a dos preguntas a la vez: ¿se levantó la aplicación y es correcto
# el número de tenant? Preguntamos el estado del sellado: es el único endpoint que OpenBao sirve
# sin token. Una respuesta vacía después significa «sin conexión», y todas las comprobaciones de
# contenido pierden sentido.
SEAL="$(bao_get "/v1/sys/seal-status")"

if [ -z "$SEAL" ]; then
  fail "OpenBao no responde en la dirección ${BAO_URL}" \
       "revisa el número de tenant en COZY_TENANT y el nombre de la aplicación (por defecto 'secrets'; si no, BAO_APP=nombre ./check.sh); en el panel la aplicación debe estar en estado listo"
else
  ok "OpenBao responde en la dirección interna del tenant"
fi

# --- 2. inicializado -------------------------------------------------------
# La inicialización es una operación única en la que el almacén crea su clave maestra y su primer
# token. Hasta que se hace, no hay nada dentro: ni secretos, ni sitio para ellos.
INITED="$(printf '%s' "$SEAL" | jget initialized)"
if [ "$INITED" = "True" ]; then
  ok "el almacén está inicializado"
elif [ -n "$SEAL" ]; then
  fail "el almacén no está inicializado" \
       "ejecuta: kubectl exec bao-workbench -- bao operator init -key-shares=1 -key-threshold=1 y guarda la salida"
fi

# --- 3. desellado ----------------------------------------------------------
# Un almacén sellado es el estado normal tras reiniciar el pod: los datos están en disco, pero no
# hay con qué leerlos hasta que se introduce la clave de unseal. De ahí la exigencia de comprobar
# el comportamiento, no la presencia de un objeto: «la aplicación está lista» y «los secretos se
# sirven» son dos afirmaciones distintas, y la segunda no se deduce de la primera.
SEALED="$(printf '%s' "$SEAL" | jget sealed)"
if [ "$SEALED" = "False" ]; then
  ok "el almacén está desellado y atiende peticiones"
  evidence "Estado del almacén" "$SEAL"
elif [ -n "$SEAL" ]; then
  fail "el almacén está sellado: responde a cualquier petición con un rechazo 503" \
       "ejecuta: kubectl exec bao-workbench -- bao operator unseal <tu-clave-de-unseal>"
  evidence "Estado del almacén" "$SEAL"
fi

# --- 4. el secreto está en su sitio y se lee -------------------------------
# A continuación hace falta un token. Sin él no hay nada que comprobar, pero tampoco podemos
# saltarlo en silencio: el lector debe ver qué falta.
if [ -z "$SEAL" ]; then
  # Sin conexión: comprobar el contenido no tiene sentido. Callamos para no inundar el informe
  # con cuatro fallos que comparten la misma causa nombrada arriba.
  warn "no se comprobó el contenido del almacén: no hay conexión con OpenBao" \
       "resuelve la conexión y luego ejecuta el script de nuevo"
elif [ -z "${BAO_TOKEN:-}" ]; then
  fail "la variable BAO_TOKEN no está definida, por eso no se comprobó el contenido del almacén" \
       "export BAO_TOKEN='token root impreso al desellar el almacén por primera vez' y ejecuta el script de nuevo"
else

  DATA="$(bao_get "/v1/secret/data/${SECRET_PATH}")"
  PASS_PRESENT="$(printf '%s' "$DATA" | jget data data password)"
  DATA_VERSION="$(printf '%s' "$DATA" | jget data metadata version)"

  if [ -n "$PASS_PRESENT" ]; then
    ok "el secreto secret/${SECRET_PATH} se lee por token, el campo password no está vacío"
    # En el informe ponemos el número de versión, no el valor.
    evidence "Secreto" "ruta: secret/${SECRET_PATH}
campo password: presente (valor oculto)
versión actual: ${DATA_VERSION:-desconocida}"
  else
    fail "no hay campo password en secret/${SECRET_PATH}" \
         "colócalo: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=... ; si el motor aún no está activado - bao secrets enable -path=secret kv-v2"
  fi

  # --- 5. la rotación de verdad ocurrió -----------------------------------
  # Una única versión del secreto significa que se puso y se olvidó. La rotación es la razón misma
  # por la que se monta un almacén: cambiar la contraseña en un solo sitio en vez de buscarla por
  # los manifiestos. No contamos promesas, sino versiones: el almacén lleva la cuenta él mismo.
  META="$(bao_get "/v1/secret/metadata/${SECRET_PATH}")"
  CUR_VER="$(printf '%s' "$META" | jget data current_version)"
  case "$CUR_VER" in
    ''|*[!0-9]*) CUR_VER=0 ;;
  esac
  if [ "$CUR_VER" -ge 2 ]; then
    ok "el secreto cambió: ${CUR_VER} versiones, así que la rotación ocurrió no solo de palabra"
    evidence "Historial de versiones del secreto" "$(printf '%s' "$META" | jget data versions)"
  else
    fail "el secreto tiene una sola versión: no se hizo rotación" \
         "cambia la contraseña: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=<nueva> y reinicia la aplicación"
  fi

  # --- 6. la política es estrecha, no «todo vale» --------------------------
  # La política es precisamente la respuesta a «qué podría hacer quien consiguió el token». Por eso
  # miramos no el hecho de que exista, sino su contenido: si se concede sobre una ruta concreta en
  # vez de sobre todo el almacén, y solo de lectura.
  POL="$(bao_get "/v1/sys/policies/acl/passes-read")"
  POL_BODY="$(printf '%s' "$POL" | jget data policy)"
  if [ -n "$POL_BODY" ]; then
    ok "la política passes-read existe"
    evidence "Política passes-read" "$POL_BODY"
    if printf '%s' "$POL_BODY" | grep -q 'secret/data/'"${SECRET_PATH}"; then
      ok "la política se concede sobre una ruta concreta, no sobre todo el almacén"
    else
      warn "la política existe, pero no se ve en ella la ruta secret/data/${SECRET_PATH}" \
           "comprueba que la política indica el prefijo data: secret/data/${SECRET_PATH}"
    fi
    if printf '%s' "$POL_BODY" | grep -Eq '"(create|update|delete|sudo)"'; then
      warn "la política permite algo más que la lectura" \
           "a la aplicación le basta con read; los permisos de más conviene quitarlos"
    fi
  else
    fail "no se encontró la política passes-read" \
         "créala: kubectl exec -i bao-workbench -- bao policy write passes-read - < tu fichero de política (el desglose de la política está en el README)"
  fi

  # --- 7. la auditoría está activada ---------------------------------------
  # Sin un audit log no hay con qué responder a «quién leyó este secreto y cuándo», y esa es la
  # primera pregunta que se hace tras un incidente. Contamos los dispositivos de auditoría
  # conectados: debe haber al menos uno.
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
    ok "el audit log está activado (dispositivos: ${AUD_COUNT})"
    evidence "Dispositivos de auditoría" "$AUD"
  else
    fail "el audit log no está activado: no habrá con qué responder quién leyó el secreto" \
         "actívalo: kubectl exec bao-workbench -- bao audit enable file file_path=stdout"
  fi
fi

# --- 8. la aplicación en el clúster de laboratorio -------------------------
# Hasta ahora comprobábamos el almacén en el clúster de gestión. A continuación viene tu clúster
# lab, donde vive la propia aplicación. Aquí no importa el hecho de que el Deployment se creara,
# sino la presencia de réplicas listas: un init container que no logró recoger la contraseña no
# dejará levantarse al pod, y es justo ese estado el que hay que distinguir de «todo bien».
if ! kubectl get deploy "$APP_DEPLOY" >/dev/null 2>&1; then
  fail "en el clúster de laboratorio no está la aplicación ${APP_DEPLOY}" \
       "aplícala: kubectl apply -f secrets-demo.yaml (sin olvidar sustituir tu número de tenant)"
else
  READY="$(kubectl get deploy "$APP_DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  case "$READY" in
    ''|*[!0-9]*) READY=0 ;;
  esac
  if [ "$READY" -ge 1 ]; then
    ok "la aplicación ${APP_DEPLOY} está en marcha (réplicas listas: ${READY})"
  else
    fail "la aplicación ${APP_DEPLOY} existe, pero ninguna réplica está lista" \
         "mira kubectl describe deploy/${APP_DEPLOY} y kubectl logs deploy/${APP_DEPLOY} -c fetch-secret - normalmente el init container no pudo alcanzar el almacén o fue rechazado por el token"
  fi

  # --- 9. no hay contraseñas en texto plano en el manifiesto ---------------
  # Miramos el objeto aplicado, no el fichero en disco: se pudo aplicar cualquier cosa.
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
            found.append("%s / env %s definido por valor, no por referencia" % (c.get("name"), e.get("name")))
print("\n".join(found))
' 2>/dev/null)"

  if [ -z "$LEAKS" ]; then
    ok "el manifiesto de la aplicación no tiene variables con contraseña definida por valor"
  else
    fail "en el manifiesto de la aplicación quedan valores sensibles en texto plano" \
         "quítalos: el valor debe venir del almacén, y en el manifiesto solo una referencia. Ver secrets-demo.yaml"
    evidence "Qué se encontró en el manifiesto" "$LEAKS"
  fi

  # --- 10. la aplicación de verdad recibió el secreto ----------------------
  # La última prueba la tomamos de los logs, no de la descripción del objeto. El manifiesto puede
  # ser impecable y aun así la contraseña no llegar al pod. Miramos dos cosas a la vez: el init
  # container informó de que fue al almacén, y la aplicación imprime una huella, lo que significa
  # que de verdad trabaja con la contraseña que recibió.
  INIT_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c fetch-secret --tail=5 2>/dev/null)"
  if printf '%s' "$INIT_LOG" | grep -qi 'openbao'; then
    ok "el init container recogió el secreto del almacén"
    evidence "Log del init container" "$INIT_LOG"
  else
    fail "no se ve que el init container recogiera el secreto del almacén" \
         "revisa kubectl logs deploy/${APP_DEPLOY} -c fetch-secret; si no hay tal container - se aplicó un manifiesto viejo"
  fi

  APP_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c app --tail=3 2>/dev/null)"
  if printf '%s' "$APP_LOG" | grep -q 'sha256:'; then
    ok "la aplicación trabaja con la contraseña recibida (en el log se escribe una huella, no el valor)"
    evidence "Log de la aplicación" "$APP_LOG"
  else
    fail "en el log de la aplicación no hay huella de la contraseña" \
         "revisa kubectl logs deploy/${APP_DEPLOY} -c app - el container pudo no arrancar"
  fi
fi

# --- 11. el secreto ingenuo está eliminado ---------------------------------
# Contamos «eliminado» solo si el lab de verdad se hizo: en un clúster limpio el secreto nunca
# existió, y el informe elogiaría al participante por una limpieza que nunca ocurrió.
if kubectl get secret passes-db >/dev/null 2>&1; then
  warn "en el clúster quedó el secreto passes-db de la etapa ingenua" \
       "ya no hace falta y contiene la contraseña vieja: kubectl delete secret passes-db"
elif kubectl get deployment secrets-demo >/dev/null 2>&1; then
  ok "el secreto ingenuo passes-db está eliminado"
fi

finish
