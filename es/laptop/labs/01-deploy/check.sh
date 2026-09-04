#!/usr/bin/env bash
# Verificación del lab 1: la aplicación está desplegada y funciona de verdad.
#
# «De verdad» aquí significa: la página se sirve realmente por HTTP, en ella se
# sustituye el nombre de un pod, y ese nombre coincide con el de una copia que
# está realmente en ejecución. Comprobar que existe un objeto Deployment no
# sirve de nada: puede existir y no funcionar.
#
# Se ejecuta en el portátil, desde la carpeta de este lab, con acceso al clúster
# de formación `lab` (no al tenant en el clúster de gestión):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/01-deploy && ./check.sh
# La variable COZY_TENANT no hace falta aquí: todo el lab transcurre dentro del clúster `lab`.
#
# El script no cambia nada en el clúster — solo lee y envía peticiones HTTP.
# Ejecútalo antes de la limpieza: tras eliminar la aplicación no habrá nada que verificar.

# Estas dos variables las recoge lib.sh — van al encabezado del informe y al nombre
# del archivo report-<lab>-<fecha>.md que el script deja junto a sí mismo.
LAB_NAME="01-deploy"
LAB_TITLE="Lab 1 · Tu primera aplicación"
# Biblioteca común de verificaciones: de aquí vienen ok / fail / warn / evidence / finish,
# la petición de la página desde dentro del clúster y la escritura del informe. La ruta se
# calcula desde donde está el propio script, así que ejecutarlo desde cualquier directorio funciona igual.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Paramos de inmediato si KUBECONFIG no está definido. Sin él kubectl busca un clúster
# en el propio portátil, no lo encuentra y tumba todas las verificaciones seguidas con el mismo
# error, que oculta la causa real.
need_kubeconfig

# --- objeto de la aplicación ------------------------------------------------
# Primera línea: la aplicación existe siquiera y al menos una copia ha alcanzado la disponibilidad.
# Miramos .status.readyReplicas, no el hecho de que exista el Deployment: el objeto
# se crea al instante y siempre con éxito, mientras que la disponibilidad significa que una copia
# se levantó, pasó su comprobación de disponibilidad y es capaz de responder.
if kubectl get deployment rickroll >/dev/null 2>&1; then
  DESIRED="$(kubectl get deployment rickroll -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  READY="$(kubectl get deployment rickroll -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  READY="${READY:-0}"
  DESIRED="${DESIRED:-0}"
  if [ "$DESIRED" -eq 0 ]; then
    # Caso especial: el objeto existe, pero tiene cero copias solicitadas. Un mensaje
    # «ninguna copia está lista (se necesitan 0)» sonaría a disparate.
    fail "aplicación detenida — se solicitaron 0 copias" \
         "recupera una copia: kubectl scale deployment rickroll --replicas=1"
  elif [ "$READY" -ge 1 ]; then
    ok "aplicación desplegada, copias listas ${READY} de ${DESIRED}"
    # Un despliegue atascado no tira el servicio: la copia vieja sigue funcionando, y
    # readyReplicas se queda en uno. Sin esta verificación el participante se va con la marca
    # verde y un deployment atascado para siempre en ErrImagePull.
    # Miramos las copias en sí, no solo ProgressDeadlineExceeded: el plazo
    # salta a los diez minutos, pero el script se ejecuta de inmediato. La copia vieja
    # mientras tanto funciona, readyReplicas se queda en uno, y sin esta verificación el participante
    # se va con la marca verde y un deployment atascado en ImagePullBackOff.
    STUCK="$(kubectl get pods -l app=rickroll \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
      | awk '$2=="ImagePullBackOff" || $2=="ErrImagePull" || $2=="CrashLoopBackOff" || $2=="CreateContainerConfigError" {print $1" ("$2")"}')"
    PROG_REASON="$(kubectl get deployment rickroll \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null)"
    if [ -n "$STUCK" ] || [ "$PROG_REASON" = "ProgressDeadlineExceeded" ]; then
      fail "el despliegue está atascado: la copia nueva no se levanta, solo funciona la vieja" \
           "mira kubectl get pods -l app=rickroll — normalmente la imagen no se descargó; restaura un estado funcional: kubectl apply -f rickroll.yaml"
      evidence "Copias que no arrancan" "${STUCK:-la causa está en el estado del Deployment: $PROG_REASON}"
    fi
  else
    fail "aplicación creada, pero ninguna copia está lista (se necesitan ${DESIRED})" \
         "mira kubectl get pods -l app=rickroll y kubectl describe deployment rickroll"
    evidence "Estado de los pods" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
  fi
else
  fail "no se encontró ningún Deployment llamado rickroll" \
       "aplica el manifiesto: kubectl apply -f rickroll.yaml"
fi

# --- configuración y página -------------------------------------------------
# Ambos ConfigMap los crea el mismo archivo que la aplicación, así que solo pueden desaparecer
# junto con ella o por una eliminación manual. Los verificamos por separado para que, cuando la
# página se rompa, el participante vea de inmediato qué falta exactamente: sin rickroll-conf
# nginx no sustituirá el nombre del pod, y sin rickroll-page-v1 no habrá con qué comparar
# la segunda versión en el lab 4 ni a dónde revertir.
for cm in rickroll-conf rickroll-page-v1; do
  if kubectl get configmap "$cm" >/dev/null 2>&1; then
    ok "configuración en su sitio: ConfigMap ${cm}"
  else
    fail "no se encontró el ConfigMap ${cm}" \
         "lo crea el mismo archivo: kubectl apply -f rickroll.yaml"
  fi
done

# --- dirección permanente ---------------------------------------------------
if kubectl get service rickroll >/dev/null 2>&1; then
  # Un Service sin endpoints es una avería típica e imperceptible: el objeto existe,
  # pero las etiquetas de los pods no coincidieron con el selector, y detrás de la dirección no hay nada.
  EPS="$(kubectl get endpoints rickroll -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
  EPS_N="$(printf '%s' "$EPS" | wc -w | tr -d ' ')"
  if [ "${EPS_N:-0}" -ge 1 ]; then
    ok "la dirección permanente funciona, copias detrás de ella: ${EPS_N}"
    evidence "Direcciones detrás del servicio" "$EPS"
  else
    fail "el Service rickroll existe, pero detrás de él no hay ni una sola copia" \
         "normalmente la causa es que las etiquetas del pod no coincidieron con el selector del servicio — comprueba app: rickroll"
  fi
else
  fail "no se encontró ningún Service llamado rickroll" \
       "lo crea el mismo archivo: kubectl apply -f rickroll.yaml"
fi

# --- lo principal: la página se sirve de verdad -----------------------------
# Por esta verificación se montó todo. Todas las anteriores solo dicen que los objetos
# en el clúster están descritos correctamente; esta dice que el usuario recibe una página. La petición va
# DESDE DENTRO del clúster, con un pod de un solo uso: desde fuera la dirección de rickroll no existe, y
# port-forward aquí sería una verificación de tu portátil, no del clúster.
# Pedimos varias veces: con varias copias detrás del servicio una muestra única
# puede no tocar la sustituida, y la verificación se pone verde con contenido ajeno.
BODY="$(in_cluster_curl_many 'http://rickroll/' 8)"
# El marcador debe aparecer EXACTAMENTE UNA VEZ por página, de lo contrario el contador de respuestas miente:
# «Never Gonna Give You Up» está tanto en <title> como en <h1>, y provocaba una duplicación.
ANSWERS="$(printf '%s' "$BODY" | grep -c 'вас обслужил под')"
TOTAL_LINES="$(printf '%s' "$BODY" | grep -c '<title>')"
if [ "${ANSWERS:-0}" -ge 1 ] && [ "${ANSWERS:-0}" -eq "${TOTAL_LINES:-0}" ]; then
  ok "la aplicación responde por HTTP y sirve su propia página (verificadas ${ANSWERS} peticiones)"
elif [ "${ANSWERS:-0}" -ge 1 ]; then
  fail "detrás del servicio no responde solo tu aplicación: tu propia página llegó ${ANSWERS} veces de ${TOTAL_LINES}" \
       "alguien más lleva la etiqueta app=rickroll — mira kubectl get pods -l app=rickroll y elimina lo sobrante"
else
  fail "la aplicación no sirvió la página esperada" \
       "comprueba a mano: kubectl port-forward svc/rickroll 8080:80, luego abre http://localhost:8080"
  evidence "Qué llegó en lugar de la página" "$(printf '%s' "$BODY" | head -20)"
fi

# --- sustitución del nombre del pod -----------------------------------------
# Para esto se hizo el lab: el nombre en la página debe coincidir con el pod real.
SERVED_BY="$(printf '%s' "$BODY" | grep -o '<b>[^<]*</b>' | head -1 | sed 's/<[^>]*>//g')"
# Tomamos los pods gestionados por el ReplicaSet de la aplicación, y NO todo lo que lleva la
# etiqueta app=rickroll. De lo contrario un pod ajeno con esa etiqueta entra en la lista de «reales»
# y se confirma a sí mismo — comprobado, un impostor pasaba la verificación así.
REAL_PODS="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
STRAY="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | awk '$2!="ReplicaSet" {print $1}')"
if [ -n "$STRAY" ]; then
  fail "pods ajenos llevan la etiqueta app=rickroll — entrarán en el balanceo" \
       "elimina lo sobrante: $(printf '%s' "$STRAY" | tr '\n' ' ')"
  evidence "Pods ajenos bajo la etiqueta de la aplicación" "$STRAY"
fi

if [ -z "$SERVED_BY" ]; then
  fail "en la página no hay nombre de pod" \
       "comprueba que se sustituyó el ConfigMap rickroll-conf — tiene la línea sub_filter '__POD__' '\$hostname'"
elif [ "$SERVED_BY" = "__POD__" ]; then
  fail "el nombre del pod no se sustituyó — en la página quedó el marcador __POD__" \
       "nginx no aplicó sub_filter: comprueba que el volumen con la configuración está montado en /etc/nginx/conf.d"
elif printf '%s' "$REAL_PODS" | grep -qx "$SERVED_BY"; then
  ok "el nombre del pod se sustituye y coincide con una copia realmente en ejecución: ${SERVED_BY}"
  evidence "Quién atendió la petición" "$SERVED_BY"
  evidence "Copias en ejecución" "$REAL_PODS"
else
  fail "la página nombra el pod «${SERVED_BY}», pero no existe tal pod en el clúster" \
       "quizá la copia se recreó entre la petición y la verificación — ejecuta el script otra vez"
fi

# --- comprobación de disponibilidad configurada -----------------------------
# Sin ella el lab sobre despliegue de versiones tendrá tiempo de inactividad, y el participante pensará que mentimos.
PROBE_PATH="$(kubectl get deployment rickroll \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE_PATH" ]; then
  ok "comprobación de disponibilidad configurada (${PROBE_PATH}) — la actualización irá sin tiempo de inactividad"
else
  warn "la aplicación no tiene comprobación de disponibilidad" \
       "el lab 4 sobre actualización sin tiempo de inactividad dará errores en una aplicación así — restaura readinessProbe desde rickroll.yaml"
fi

finish
