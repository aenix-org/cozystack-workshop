#!/usr/bin/env bash
# Comprobación del lab 6: la aplicación llega al clúster desde SU PROPIO registro privado.
#
# No comprobamos «Harbor está creado», sino toda la cadena: el registro responde en su propia API,
# la imagen del manifiesto está justamente en él, el clúster tiene credenciales para esa misma dirección,
# y un pod con esta imagen realmente funciona y responde.
#
# Dos clústeres, y esta es la razón principal por la que el script parece más complejo que sus vecinos:
# KUBECONFIG es tu clúster lab, donde funciona la aplicación; COZY_KUBECONFIG es el
# clúster de gestión de Cozystack, donde vive el servicio gestionado Harbor en tu tenant.
# No se pueden consultar con un solo comando, por eso abajo hay dos formas distintas de llamar a kubectl.
#
# Lo ejecutas tú, desde la carpeta del lab; no cambia nada, solo mira e imprime un informe:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_KUBECONFIG=~/.kube/config
#     ./check.sh

LAB_NAME="06-harbor"
LAB_TITLE="Lab 6 · Tu propio registro privado de imágenes"
# Envoltura común de todos los labs: ok / fail / warn / evidence / finish y comprobaciones del entorno.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Sin el archivo de acceso al clúster y sin el número de tenant no hay nada que comprobar — salimos enseguida.
need_kubeconfig
need_tenant

APP="passes-api"
# El namespace del tenant en el clúster de gestión: el nombre se construye a partir del prefijo
# tenant- y tu número, es decir tenant-workshopXX. El número se toma del entorno,
# no hace falta sustituirlo a mano en el texto del script.
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/config}"

# Dos formas de llamar a kubectl: kget va a tu clúster lab, cozy — al clúster de gestión.
# Los errores se silencian a propósito: la ausencia de un objeto aquí no es un fallo sino uno de los
# resultados esperados, y se maneja abajo con una rama aparte y un consejo claro.
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- servicio gestionado Harbor en el clúster de gestión ---------------------
# Parte opcional: sin el kubeconfig del tenant el lab sigue siendo comprobable,
# pero no veremos el servicio desde el lado de la plataforma.
#
# Capturamos aparte el caso «el comando no funcionó»: el rol en el tenant puede no permitir
# ver las aplicaciones. Esto no es un error del participante ni motivo para tumbar la comprobación, por eso
# aquí es warn — «no miramos», no fail — «hecho mal». Distinguimos a propósito el error del comando y
# la respuesta vacía: una lista vacía significa que Harbor no se creó en absoluto.
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "no se encontró el kubeconfig del tenant ${COZY_KUBECONFIG} — el estado de Harbor no se comprobó" \
       "indica la ruta: export COZY_KUBECONFIG=~/.kube/config"
else
  HARBOR_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get harbors.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  HARBOR_LIST="$(cozy get harbors.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$HARBOR_ERR" ]; then
    warn "no se pudieron ver las aplicaciones Harbor en el tenant ${TENANT_NS}" \
         "el rol en el tenant puede no permitir este comando — esto no es un error del lab; todo lo demás se comprueba abajo"
  elif [ -z "$HARBOR_LIST" ]; then
    fail "en el tenant ${TENANT_NS} no hay ninguna aplicación Harbor" \
         "créala en el dashboard: Crear aplicación -> Harbor"
  else
    HARBOR_NAME="$(printf '%s' "$HARBOR_LIST" | awk 'NR==1{print $1}')"
    HARBOR_READY="$(cozy get harbors.apps.cozystack.io "$HARBOR_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$HARBOR_READY" = "True" ]; then
      ok "el servicio gestionado Harbor «${HARBOR_NAME}» está listo"
    else
      warn "Harbor «${HARBOR_NAME}» existe, pero no informa de que esté listo" \
           "mira su estado en el dashboard; Harbor tarda 5-10 minutos en arrancar, y sin almacenamiento de objetos en el tenant no arrancará en absoluto"
    fi
    evidence "Aplicaciones Harbor en el tenant" "$HARBOR_LIST"
    # No intentamos leer el secreto con las credenciales: el tenant puede leer este secreto
    # (la plataforma crea una regla aparte para las credenciales de cada aplicación),
    # pero de todos modos no necesitamos la contraseña en el informe.
  fi
fi

# --- de dónde toma la aplicación la imagen ----------------------------------
# El sentido del lab es que la imagen vino de tu registro, no de internet. Esto se comprueba
# por el nombre de la imagen en el manifiesto: la primera parte del nombre hasta la barra es la dirección del registro.
# Si no tiene ni punto ni dos puntos, ahí no hay dirección alguna, y el clúster iría en silencio
# a por la imagen a Docker Hub — es decir, exactamente a donde el equipo de seguridad lo prohibió.
# El marcador HARBOR-HOST y los registros públicos conocidos los capturamos en ramas aparte:
# formalmente la dirección está puesta, pero el requisito del lab no se cumple, y el consejo es distinto en cada caso.
IMAGE="$(kget deployment "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}')"
REGISTRY=""
if [ -z "$IMAGE" ]; then
  fail "en el clúster lab no existe la aplicación ${APP}" \
       "aplica passes.yaml, sustituyendo en él la dirección de tu propio Harbor"
else
  REGISTRY="${IMAGE%%/*}"
  case "$REGISTRY" in
    *.*|*:*) : ;;              # parece una dirección de registro
    *) REGISTRY="" ;;          # no hay dirección — significa que la imagen se tira de Docker Hub
  esac

  if [ -z "$REGISTRY" ]; then
    fail "la imagen ${IMAGE} se tira de un registro público, no del tuyo" \
         "la primera parte del nombre de la imagen debe ser la dirección de tu Harbor"
  elif printf '%s' "$REGISTRY" | grep -qi 'HARBOR-HOST'; then
    fail "en el manifiesto quedó la dirección-marcador HARBOR-HOST" \
         "sustituye la dirección de tu propio Harbor: sed -i 's|HARBOR-HOST|harbor.tudominio|g' passes.yaml"
  elif printf '%s' "$REGISTRY" | grep -qiE '^(docker\.io|registry-1\.docker\.io|quay\.io|ghcr\.io|gcr\.io|registry\.k8s\.io)$'; then
    fail "la imagen se tira del registro público ${REGISTRY}" \
         "el equipo de seguridad pidió un registro privado — construye y sube la imagen a tu propio Harbor"
  else
    ok "la aplicación arranca desde tu registro: ${REGISTRY}"
    evidence "Imagen de la aplicación" "$IMAGE"
  fi
fi

# --- el registro realmente funciona -----------------------------------------
# La dirección en el manifiesto puede estar escrita correctamente, pero puede no haber registro en ella: Harbor
# no arranca al instante, y una errata en el dominio se ve exactamente igual. Por eso
# llamamos a su API y esperamos la respuesta «pong» — esto confirma que ahí hay justamente Harbor,
# y no el sitio de otra persona ni un stub del balanceador.
if [ -z "$REGISTRY" ]; then
  : # ya se informó arriba
elif ! command -v curl >/dev/null 2>&1; then
  warn "no hay utilidad curl — la disponibilidad del registro no se comprobó" \
       "abre https://${REGISTRY} en el navegador, ahí debería estar la interfaz de Harbor"
else
  PING="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/ping" 2>/dev/null)"
  if printf '%s' "$PING" | grep -qi 'pong'; then
    VER="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/systeminfo" 2>/dev/null \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("harbor_version","desconocida"))' 2>/dev/null)"
    ok "el registro responde por la API: https://${REGISTRY} (Harbor ${VER:-versión desconocida})"
    evidence "Registro" "https://${REGISTRY}
API ping: ${PING}
versión de Harbor: ${VER:-desconocida}"
  else
    fail "el registro https://${REGISTRY} no responde a la petición /api/v2.0/ping" \
         "comprueba la dirección y el estado de la aplicación Harbor en el dashboard"
  fi
fi

# --- el clúster tiene credenciales de acceso --------------------------------
# No basta con que el secreto esté referenciado en el manifiesto — lo importante es que tenga credenciales
# justamente para el registro del que se tira la imagen. El error más frecuente del lab parece
# correcto: el secreto está creado, nombrado en el manifiesto, pero la dirección dentro de él no es la buena
# (un https:// de más, un puerto, otro nombre de host), y kubelet no lo aplicará.
# Por eso desempaquetamos el contenido del secreto y comparamos direcciones, no nombres.
PULL_SECRETS="$(kget deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.imagePullSecrets[*]}{.name}{"\n"}{end}')"
if [ -z "$IMAGE" ]; then
  : # no hay aplicación, se informó arriba
elif [ -z "$PULL_SECRETS" ]; then
  fail "en el manifiesto ${APP} no se indica ningún imagePullSecret" \
       "una imagen de un registro privado no se descargará sin credenciales: añade imagePullSecrets, ver passes.yaml"
else
  SECRET_OK=""
  for s in $PULL_SECRETS; do
    STYPE="$(kget secret "$s" -o jsonpath='{.type}')"
    [ "$STYPE" = "kubernetes.io/dockerconfigjson" ] || continue
    # Analizamos el config con python: base64 -d se comporta de forma distinta en macOS y Linux,
    # y no se puede imprimir la contraseña en el informe — tomamos solo la lista de direcciones.
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
    ok "el clúster tiene credenciales para ${REGISTRY} en el secreto ${SECRET_OK} (contraseña: <oculta>)"
  else
    fail "ninguno de los secretos indicados (${PULL_SECRETS}) contiene credenciales para ${REGISTRY:-tu registro}" \
         "créalo así: kubectl create secret docker-registry harbor --docker-server=${REGISTRY:-DIRECCIÓN} --docker-username=admin --docker-password=..."
  fi
fi

# --- los pods realmente arrancaron ------------------------------------------
# Manejamos aparte los estados ImagePullBackOff y ErrImagePull: este es justamente el fallo
# que el lab muestra a propósito, y es importante que el participante lo reconozca de vista, y no
# reciba un genérico «los pods no funcionan». La causa real la imprimimos como evidencia —
# en un fallo del registro y en una errata en el nombre de la imagen el estado del pod es el mismo.
PODS="$(kget pods -l app=passes-api --no-headers)"
RUNNING="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BADSTATE="$(printf '%s' "$PODS" | awk '$3!="Running"{print $3}' | sort -u | tr '\n' ' ')"

if [ "$RUNNING" -ge 1 ]; then
  ok "copias en ejecución de la aplicación: ${RUNNING}"
  evidence "Pods de la aplicación" "$(kget pods -l app=passes-api -o wide)"
elif printf '%s' "$BADSTATE" | grep -q 'ImagePullBackOff\|ErrImagePull'; then
  fail "la imagen no se descarga: ${BADSTATE}" \
       "esto es una denegación de acceso al registro o una errata en el nombre de la imagen; la causa real la mostrará kubectl describe pod -l app=passes-api"
  evidence "Causa del fallo" "$(kubectl describe pod -l app=passes-api 2>/dev/null \
    | grep -A2 'Failed to pull\|Warning' | head -20)"
else
  fail "no hay ni una sola copia en ejecución de la aplicación (estados: ${BADSTATE:-no hay pods})" \
       "mira kubectl describe pod -l app=passes-api"
fi

# Una comprobación aparte para el error del lab más difícil de diagnosticar: la imagen está construida
# para ARM, y los nodos del clúster son x86. Todo parece correcto — la imagen se construyó, se fue
# al registro, se descargó en el nodo — pero el proceso no arranca. Nada alrededor sugiere
# la arquitectura del procesador, y la única pista está en los logs del pod, por eso
# los miramos con una comprobación aparte y nombramos la causa directamente.
LOGS="$(kubectl logs -l app=passes-api --tail=20 --all-containers 2>&1)"
if printf '%s' "$LOGS" | grep -q 'exec format error'; then
  fail "la imagen está construida para otra arquitectura de procesador" \
       "reconstruye con el flag: docker build --platform linux/amd64 -t ${IMAGE} app/ y súbela de nuevo"
fi

# --- la aplicación responde de verdad ---------------------------------------
# Un pod arrancado no significa todavía un servicio en funcionamiento. Entramos dentro del clúster, pedimos
# la aplicación por su nombre interno y leemos de la respuesta el nombre del pod. Si coincide con un pod
# realmente en ejecución — entonces responde justamente la aplicación que desplegamos, y no
# otra cosa que ocupó por casualidad esta dirección. Una discrepancia es warn, no fail:
# la copia pudo recrearse entre las dos peticiones, y la culpa no es del participante.
if [ -z "$(kget svc "$APP" -o name)" ]; then
  fail "no hay Service con el nombre ${APP}" \
       "está descrito en passes.yaml — aplica el archivo entero, no solo el Deployment"
else
  BODY="$(in_cluster_curl "http://${APP}.default.svc.cluster.local/")"
  SERVED_POD="$(printf '%s' "$BODY" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("pod",""))
except Exception: pass' 2>/dev/null)"

  if [ -z "$SERVED_POD" ]; then
    fail "el servicio ${APP} no devolvió el JSON esperado" \
         "mira kubectl logs -l app=passes-api y asegúrate de que el puerto del Service coincide con el puerto de la aplicación"
  elif printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
    ok "el servicio responde con JSON, la respuesta vino de un pod realmente en ejecución ${SERVED_POD}"
    evidence "Respuesta del servicio" "$BODY"
  else
    warn "el servicio respondió en nombre del pod ${SERVED_POD}, que no está entre los que están en ejecución" \
         "lo más probable es que la copia se recreara entre peticiones — ejecuta la comprobación otra vez"
  fi
fi

finish
