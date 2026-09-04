#!/usr/bin/env bash
# Comprobación del lab 4: despliegue de una nueva versión y reversión.
#
# Verificamos la esencia, no los comandos escritos:
#   - el historial de la aplicación tiene varias revisiones, es decir, la versión se cambió de verdad;
#   - el ConfigMap de la segunda versión está en el clúster como objeto aparte, no como edición del primero;
#   - el contenedor tiene un readinessProbe — sin él el tiempo de inactividad cero no es reproducible;
#   - el despliegue llegó a su fin y no se quedó atascado;
#   - la página que sirve el Service coincide con el ConfigMap al que hace referencia
#     la especificación. Esto detecta el caso «se revirtió la especificación, pero los pods no se recrearon».
#
# El script no cambia nada. El pod de un solo uso solo hace falta para recoger la página
# desde dentro del clúster y se elimina a sí mismo.
#
# Se ejecuta en la máquina virtual, desde la carpeta de este lab, con acceso al clúster de formación `lab`
# (no al tenant en el clúster de gestión):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/04-rollout && ./check.sh
# La variable COZY_TENANT no hace falta aquí: todo el lab transcurre dentro del clúster `lab`.
#
# Ejecútalo ANTES de la limpieza y después de que la reversión haya terminado: el historial de revisiones vive
# junto con el Deployment, y desaparece junto con él.

# Van a la cabecera del informe y al nombre del archivo report-<lab>-<fecha>.md junto al script.
LAB_NAME="04-rollout"
LAB_TITLE="Lab 4 · Despliegue de una nueva versión y reversión"
# Biblioteca común: ok / fail / warn / evidence / finish, peticiones desde dentro del clúster,
# escritura del informe. La ruta se calcula desde la ubicación del propio script, no desde el directorio actual.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Sin KUBECONFIG kubectl busca un clúster en la máquina virtual y hace fallar todo con un único error
# en el que no se distingue la causa real. Nos detenemos de inmediato.
need_kubeconfig

APP=rickroll

# --- la aplicación está en su sitio y llevada a un estado operativo ------------------
# Sin la aplicación no hay nada que comprobar, por eso esta es la única salida anticipada.
# Más adelante miramos no solo el número de copias listas, sino también el motivo en la condición
# Progressing: NewReplicaSetAvailable significa que el despliegue está COMPLETO. Solo las copias
# listas no bastan — con una actualización atascada corre la versión antigua, el contador
# muestra el número esperado, y sin embargo la nueva copia no llegó a levantarse ni una vez.
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "la aplicación ${APP} no está en el clúster" \
       "despliégala: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

PROG_REASON="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.reason}{end}' 2>/dev/null)"

if [ "$HAVE" = "$WANT" ] && [ "${HAVE:-0}" -ge 1 ] && [ "$PROG_REASON" = "NewReplicaSetAvailable" ]; then
  ok "el despliegue llegó a su fin: ${HAVE} de ${WANT} copias listas"
else
  fail "la aplicación no está en un estado completado (${HAVE} de ${WANT} listas, motivo: ${PROG_REASON:-ninguno})" \
       "si el despliegue está atascado — sal mediante reversión: kubectl rollout undo deployment/${APP}"
fi
evidence "Estado de la aplicación" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- readinessProbe: lo que paga el tiempo de inactividad cero -----------------------
PROBE="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE" ]; then
  ok "el contenedor tiene un readinessProbe (${PROBE}) — las copias se reemplazan solo tras estar listas"
else
  fail "el contenedor no tiene readinessProbe" \
       "sin él el clúster envía tráfico a una copia que no está lista; aplica ../01-deploy/rickroll.yaml"
fi

# --- versiones hechas como objetos separados --------------------------------------
# Ambas versiones de la página deben estar en el clúster como dos ConfigMap separados.
# Quien en su lugar editó rickroll-page-v1 sobre la marcha verá la nueva página en pantalla
# y decidirá que el lab está hecho, — pero no habrá adónde revertir,
# y no ocurrirá ningún reemplazo de copias ni entrada en el historial de revisiones.
if kubectl get configmap rickroll-page-v2 >/dev/null 2>&1; then
  ok "el ConfigMap rickroll-page-v2 está en el clúster como objeto aparte"
else
  fail "no hay ConfigMap rickroll-page-v2 en el clúster" \
       "aplícalo: kubectl apply -f rickroll-page-v2.yaml"
fi

if kubectl get configmap rickroll-page-v1 >/dev/null 2>&1; then
  ok "la primera versión de la página también está conservada — hay adónde revertir"
else
  warn "no se encontró el ConfigMap rickroll-page-v1 en el clúster" \
       "una reversión a la primera versión sin él no levantará los pods: kubectl apply -f ../01-deploy/rickroll.yaml"
fi

# --- historial de revisiones -------------------------------------------------------
# Miramos el NÚMERO de la última revisión, no la cantidad de líneas del historial. Una reversión
# no añade un nuevo ReplicaSet — reutiliza el antiguo y sube su número,
# por eso tras una reversión hay las mismas líneas en el historial, mientras el número crece.
#   1 — la especificación no se cambió ni una vez
#   2 — la versión se conmutó
#   3 y más — se conmutó y se revirtió
REV_MAX="$(kubectl rollout history deployment/${APP} 2>/dev/null \
  | awk '$1 ~ /^[0-9]+$/ { if ($1+0 > m) m = $1+0 } END { print m+0 }')"
[ -z "$REV_MAX" ] && REV_MAX=0

if [ "$REV_MAX" -ge 3 ]; then
  ok "la última revisión de la aplicación es ${REV_MAX}: la versión se conmutó y se revirtió"
elif [ "$REV_MAX" -eq 2 ]; then
  warn "la última revisión es 2: el despliegue está hecho, la reversión todavía no" \
       "restaura la primera versión: kubectl rollout undo deployment/${APP}"
else
  fail "la última revisión es ${REV_MAX}: la especificación de la aplicación no se cambió ni una vez" \
       "conmuta el volumen a la segunda versión con el parche del lab, luego revierte"
fi
evidence "Historial de revisiones" "$(kubectl rollout history deployment/${APP} 2>/dev/null)"

# --- a qué versión apunta la especificación --------------------------------------
# Buscamos el volumen POR EL NOMBRE page, aunque el parche del lab lo direcciona por índice.
# La diferencia es justo lo que se detecta aquí: si el parche fue al elemento equivocado de la lista,
# el nombre page apuntará al ConfigMap anterior o desaparecerá, y el participante se enterará
# de ello con palabras, en vez de con un extraño error de nginx.
VOL_CM="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.volumes[?(@.name=="page")]}{.configMap.name}{end}' 2>/dev/null)"

case "$VOL_CM" in
  rickroll-page-v1)
    ok "la especificación de la aplicación se ha revertido a la primera versión de la página"
    ;;
  rickroll-page-v2)
    warn "la especificación de la aplicación apunta a la segunda versión de la página" \
         "el lab termina con una reversión; si es intencionado — no hay de qué preocuparse, si no: kubectl rollout undo deployment/${APP}"
    ;;
  "")
    fail "la especificación no tiene un volumen llamado page" \
         "parece que el parche cayó en el lugar equivocado (¡direccionamiento por índice!); aplica ../01-deploy/rickroll.yaml de nuevo"
    ;;
  *)
    fail "el volumen page apunta al ConfigMap ${VOL_CM}, que el lab no creó" \
         "revierte: kubectl rollout undo deployment/${APP}"
    ;;
esac

# --- qué se sirve realmente al cliente ------------------------------------
# La comprobación más sustanciosa: comparamos la especificación con lo que ve el usuario.
# Una discrepancia aquí significa que los pods no se recrearon para la nueva especificación.
# Ocho peticiones, no una. Hay tres copias detrás del service; si el despliegue no convergió del todo,
# una única petición tiene una probabilidad de una entre tres de dar con la versión correcta y ocultar la discrepancia.
BODIES="$(in_cluster_curl_many "http://${APP}/" 8)"
BODY="$BODIES"

if [ -z "$BODY" ]; then
  fail "el Service ${APP} no devolvió una página desde dentro del clúster" \
       "comprueba los endpoints: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
else
  # Detectamos ambas versiones de forma POSITIVA, cada una por su propio marcador. La rama «si no es v2, entonces
  # v1» contaba cualquier cosa como la primera versión: la página por defecto de nginx, un 404, la aplicación
  # de otro, basura — comprobado, con basura el script imprimía «LAB APROBADO».
  if printf '%s' "$BODY" | grep -q 'ВЕРСИЯ 2'; then
    SERVED_VER="rickroll-page-v2"
  elif printf '%s' "$BODY" | grep -q 'Never Gonna Give You Up'; then
    SERVED_VER="rickroll-page-v1"
  else
    SERVED_VER=""
    fail "en la dirección del servicio se sirve algo que no es la página de la aplicación" \
         "ni un solo marcador conocido en la respuesta — restaura el original: kubectl apply -f ../01-deploy/rickroll.yaml"
    evidence "Qué se devolvió en lugar de la página" "$(printf '%s' "$BODY" | head -12)"
  fi

  if [ -n "$VOL_CM" ] && [ "$SERVED_VER" = "$VOL_CM" ]; then
    ok "al cliente se le sirve exactamente la versión registrada en la especificación (${SERVED_VER})"
  elif [ -n "$VOL_CM" ]; then
    fail "la especificación apunta a ${VOL_CM}, pero al cliente se le sirve ${SERVED_VER}" \
         "las copias no se recrearon para la nueva especificación: kubectl rollout status deployment/${APP}"
  fi

  if printf '%s' "$BODY" | grep -q '__POD__'; then
    fail "el nombre de la copia no se sustituye en la página" \
         "se perdió el ConfigMap rickroll-conf: aplica ../01-deploy/rickroll.yaml por completo"
  else
    SERVED_POD="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
    if [ -n "$SERVED_POD" ] && kubectl get pod "$SERVED_POD" >/dev/null 2>&1; then
      ok "la página la sirvió una copia viva ${SERVED_POD}"
    else
      warn "no se pudo emparejar el nombre de la página con una copia en ejecución" \
           "probablemente las copias estaban cambiando durante la propia comprobación — ejecuta el script otra vez"
    fi
  fi

  evidence "Página servida (fragmento)" \
    "$(printf '%s' "$BODY" | grep -o '<h1>[^<]*</h1>' | head -1)
$(printf '%s' "$BODY" | grep -o "вас обслужил под<b>${APP}-[a-z0-9-]*</b>" | head -1)"
fi

# --- preparación para los siguientes labs ------------------------------------
# El lab escaló las copias hasta tres para que el reemplazo se viera una a una. Las tres
# copias sobrantes no rompen nada — de ahí un warn, no un fail, — pero ocupan espacio en el nodo
# de formación, que a los labs vecinos les faltará más adelante.
if [ "$WANT" = "1" ]; then
  ok "el número de copias se ha devuelto a una"
else
  warn "actualmente se piden copias: ${WANT}" \
       "tras el lab conviene volver a una: kubectl scale deployment ${APP} --replicas=1"
fi

finish
