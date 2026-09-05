#!/usr/bin/env bash
# Comprobación del lab 4: despliegue de una nueva versión y reversión.
#
# Comprobamos la sustancia, no los comandos que se teclearon:
#   - el historial de la app tiene varias revisiones, es decir, la versión se cambió realmente;
#   - el ConfigMap de la segunda versión existe en el clúster como objeto separado, no como edición del primero;
#   - el contenedor tiene readinessProbe — sin ella el cero tiempo de inactividad no es reproducible;
#   - el despliegue está completado, no atascado;
#   - la página que sirve el Service coincide con el ConfigMap al que hace referencia
#     la especificación. Esto detecta el caso «se revirtió la especificación, pero los pods no se recrearon».
#
# El script no cambia nada. El pod de un solo uso solo hace falta para recoger la página
# desde dentro del clúster y se elimina a sí mismo.
#
# Se ejecuta en el portátil, desde la carpeta de este lab, con acceso al clúster de formación `lab`
# (no al tenant en el clúster de gestión):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/04-rollout && ./check.sh
# La variable COZY_TENANT no hace falta aquí: todo el lab transcurre dentro del clúster `lab`.
#
# Ejecutar ANTES de la limpieza y después de que la reversión haya terminado: el historial de revisiones vive
# junto con el Deployment, y desaparece junto con él.

# Van a la cabecera del informe y al nombre del archivo report-<lab>-<fecha>.md junto al script.
LAB_NAME="04-rollout"
LAB_TITLE="Lab 4 · Despliegue de una nueva versión y reversión"
# Biblioteca común: ok / fail / warn / evidence / finish, peticiones desde dentro del clúster,
# escritura del informe. La ruta se resuelve desde la ubicación del propio script, no desde el directorio actual.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Sin KUBECONFIG kubectl busca un clúster en el portátil y falla todo con un único error
# en el que no se distingue la causa real. Paramos de inmediato.
need_kubeconfig

APP=rickroll

# --- la app está presente y llevada a un estado funcional ------------------
# Sin app no hay nada que comprobar, por eso esta es la única salida temprana.
# Después miramos no solo el número de copias listas, sino también la razón en la condición
# Progressing: NewReplicaSetAvailable significa que el despliegue está COMPLETADO. Las copias
# listas por sí solas no bastan — con una actualización atascada corre la versión antigua, el contador
# muestra el número esperado, mientras que la nueva copia no llegó a levantarse ni una vez.
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "la app ${APP} no está en el clúster" \
       "despliéguela: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

PROG_REASON="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.reason}{end}' 2>/dev/null)"

if [ "$HAVE" = "$WANT" ] && [ "${HAVE:-0}" -ge 1 ] && [ "$PROG_REASON" = "NewReplicaSetAvailable" ]; then
  ok "despliegue completado: ${HAVE} de ${WANT} copias listas"
else
  fail "la app no está en estado completado (${HAVE} de ${WANT} listas, razón: ${PROG_REASON:-ninguna})" \
       "si el despliegue está atascado — recupérese con una reversión: kubectl rollout undo deployment/${APP}"
fi
evidence "Estado de la app" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- readinessProbe: lo que paga el cero tiempo de inactividad -----------------------
PROBE="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE" ]; then
  ok "el contenedor tiene una readinessProbe (${PROBE}) — las copias se cambian solo después de estar listas"
else
  fail "el contenedor no tiene readinessProbe" \
       "sin ella el clúster envía tráfico a una copia no lista; aplique ../01-deploy/rickroll.yaml"
fi

# --- las versiones se hacen como objetos separados --------------------------------------
# Ambas versiones de la página deben existir en el clúster como dos ConfigMap separados.
# Quien en su lugar editó rickroll-page-v1 en el sitio verá la nueva página en pantalla
# y decidirá que el lab está hecho — pero no habrá adónde revertir,
# y no ocurrirá ni el cambio de copias ni la entrada en el historial de revisiones.
if kubectl get configmap rickroll-page-v2 >/dev/null 2>&1; then
  ok "el ConfigMap rickroll-page-v2 existe en el clúster como objeto separado"
else
  fail "el ConfigMap rickroll-page-v2 no está en el clúster" \
       "aplíquelo: kubectl apply -f rickroll-page-v2.yaml"
fi

if kubectl get configmap rickroll-page-v1 >/dev/null 2>&1; then
  ok "la primera versión de la página también se conserva — hay adónde revertir"
else
  warn "ConfigMap rickroll-page-v1 no encontrado en el clúster" \
       "una reversión a la primera versión no levantará los pods sin él: kubectl apply -f ../01-deploy/rickroll.yaml"
fi

# --- historial de revisiones -------------------------------------------------------
# Miramos el NÚMERO de la última revisión, no el número de líneas del historial. Una reversión
# no añade un nuevo ReplicaSet — reutiliza el antiguo y sube su número,
# por eso tras una reversión el historial tiene el mismo número de líneas, pero el número crece.
#   1 — la especificación nunca se cambió
#   2 — la versión se cambió
#   3 y más — cambiada y revertida
REV_MAX="$(kubectl rollout history deployment/${APP} 2>/dev/null \
  | awk '$1 ~ /^[0-9]+$/ { if ($1+0 > m) m = $1+0 } END { print m+0 }')"
[ -z "$REV_MAX" ] && REV_MAX=0

if [ "$REV_MAX" -ge 3 ]; then
  ok "la última revisión de la app es ${REV_MAX}: la versión se cambió y se revirtió"
elif [ "$REV_MAX" -eq 2 ]; then
  warn "la última revisión es 2: despliegue hecho, reversión aún no" \
       "restaure la primera versión: kubectl rollout undo deployment/${APP}"
else
  fail "la última revisión es ${REV_MAX}: la especificación de la app nunca se cambió" \
       "cambie el volumen a la segunda versión con el parche del lab, luego revierta"
fi
evidence "Historial de revisiones" "$(kubectl rollout history deployment/${APP} 2>/dev/null)"

# --- a qué versión apunta la especificación --------------------------------------
# Buscamos el volumen POR el nombre page, aunque el parche del lab lo direcciona por índice. La
# diferencia se detecta justo aquí: si el parche fue al elemento de lista equivocado, el nombre page apuntará
# al ConfigMap antiguo o desaparecerá, y el participante se enterará con palabras, no
# mediante un extraño error de nginx.
VOL_CM="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.volumes[?(@.name=="page")]}{.configMap.name}{end}' 2>/dev/null)"

case "$VOL_CM" in
  rickroll-page-v1)
    ok "la especificación de la app se ha revertido a la primera versión de la página"
    ;;
  rickroll-page-v2)
    warn "la especificación de la app apunta a la segunda versión de la página" \
         "el lab termina con una reversión; si es intencionado — no hay problema, si no: kubectl rollout undo deployment/${APP}"
    ;;
  "")
    fail "la especificación no tiene ningún volumen llamado page" \
         "parece que el parche fue al lugar equivocado (¡direccionamiento por índice!); aplique ../01-deploy/rickroll.yaml de nuevo"
    ;;
  *)
    fail "el volumen page apunta al ConfigMap ${VOL_CM}, que el lab no creó" \
         "revierta: kubectl rollout undo deployment/${APP}"
    ;;
esac

# --- qué se sirve realmente al cliente ------------------------------------
# La comprobación más significativa: comparamos la especificación con lo que ve el usuario.
# Una discrepancia aquí significa que los pods no se recrearon para la nueva especificación.
# Ocho peticiones, no una. Detrás del Service hay tres copias; si el despliegue no convergió del todo,
# una única petición tiene una probabilidad de un tercio de acertar la versión correcta y ocultar la discrepancia.
BODIES="$(in_cluster_curl_many "http://${APP}/" 8)"
BODY="$BODIES"

if [ -z "$BODY" ]; then
  fail "el Service ${APP} no devolvió una página desde dentro del clúster" \
       "compruebe los endpoints: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
else
  # Identificamos ambas versiones POSITIVAMENTE, cada una por su propio marcador. La rama «si no es v2,
  # entonces v1» contaba cualquier cosa como la primera versión: la página por defecto de nginx, un 404,
  # la app de otro, basura — comprobado, con basura el script informaba «LAB APROBADO».
  if printf '%s' "$BODY" | grep -q 'VERSIÓN 2'; then
    SERVED_VER="rickroll-page-v2"
  elif printf '%s' "$BODY" | grep -q 'Never Gonna Give You Up'; then
    SERVED_VER="rickroll-page-v1"
  else
    SERVED_VER=""
    fail "la dirección del servicio devuelve algo distinto de la página de la app" \
         "ningún marcador conocido en la respuesta — restaure el original: kubectl apply -f ../01-deploy/rickroll.yaml"
    evidence "Lo que volvió en lugar de la página" "$(printf '%s' "$BODY" | head -12)"
  fi

  if [ -n "$VOL_CM" ] && [ "$SERVED_VER" = "$VOL_CM" ]; then
    ok "al cliente se le sirve exactamente la versión registrada en la especificación (${SERVED_VER})"
  elif [ -n "$VOL_CM" ]; then
    fail "la especificación apunta a ${VOL_CM}, pero al cliente se le sirve ${SERVED_VER}" \
         "las copias no se recrearon para la nueva especificación: kubectl rollout status deployment/${APP}"
  fi

  if printf '%s' "$BODY" | grep -q '__POD__'; then
    fail "el nombre de la copia no se sustituye en la página" \
         "se ha perdido el ConfigMap rickroll-conf: aplique todo ../01-deploy/rickroll.yaml"
  else
    SERVED_POD="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
    if [ -n "$SERVED_POD" ] && kubectl get pod "$SERVED_POD" >/dev/null 2>&1; then
      ok "la página la sirvió una copia viva ${SERVED_POD}"
    else
      warn "no se pudo emparejar el nombre de la página con una copia en ejecución" \
           "probablemente las copias cambiaban durante la comprobación — ejecute el script otra vez"
    fi
  fi

  evidence "Página servida (fragmento)" \
    "$(printf '%s' "$BODY" | grep -o '<h1>[^<]*</h1>' | head -1)
$(printf '%s' "$BODY" | grep -o "te atendió el Pod<b>${APP}-[a-z0-9-]*</b>" | head -1)"
fi

# --- preparación para los siguientes labs ------------------------------------
# El lab subió las copias hasta tres para que el cambio se viera una a una. Las tres copias
# dejadas no rompen nada — de ahí warn, no fail — pero ocupan sitio en el nodo de
# formación, del que más adelante carecerán los labs vecinos.
if [ "$WANT" = "1" ]; then
  ok "el número de copias se ha devuelto a una"
else
  warn "actualmente se solicitan copias: ${WANT}" \
       "tras el lab conviene volver a una: kubectl scale deployment ${APP} --replicas=1"
fi

finish
