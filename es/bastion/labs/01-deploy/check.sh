#!/usr/bin/env bash
# Comprobación del lab 1: la aplicación está desplegada y funciona de verdad.
#
# «De verdad» aquí significa: la página se sirve realmente por HTTP, tiene el nombre
# del pod sustituido en ella, y ese nombre coincide con el de una réplica realmente en marcha.
# Comprobar que existe el objeto Deployment no sirve de nada — puede existir y no funcionar.
#
# Se ejecuta en la VM, desde la carpeta de este lab, con acceso al clúster de formación `lab`
# (no al tenant en el clúster de gestión):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/01-deploy && ./check.sh
# La variable COZY_TENANT no hace falta aquí: todo el lab transcurre dentro del clúster `lab`.
#
# El script no cambia nada en el clúster — solo lee y envía peticiones HTTP.
# Ejecútalo antes de la limpieza: tras borrar la aplicación no quedará nada que comprobar.

# lib.sh recoge estas dos variables — van a la cabecera del informe y al nombre del
# fichero report-<lab>-<fecha>.md que el script escribe junto a sí mismo.
LAB_NAME="01-deploy"
LAB_TITLE="Lab 1 · Primera aplicación"
# La biblioteca común de comprobaciones: de aquí vienen ok / fail / warn / evidence / finish,
# la petición de la página desde dentro del clúster y la escritura del informe. La ruta se
# calcula desde donde está el propio script, así que ejecutarlo desde cualquier directorio funciona igual.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Paramos de inmediato si KUBECONFIG no está definido. Sin él kubectl busca un clúster
# en la propia VM, no lo encuentra y hace fallar todas las comprobaciones seguidas con el mismo error,
# que oculta la causa real.
need_kubeconfig

# --- objeto de la aplicación ------------------------------------------------
# Primera línea de defensa: la aplicación está realmente configurada y al menos una réplica alcanzó la disponibilidad.
# Miramos .status.readyReplicas, no el mero hecho de que exista el Deployment: el objeto
# se crea al instante y siempre con éxito, mientras que la disponibilidad significa que una réplica se levantó,
# pasó su prueba de disponibilidad y es capaz de responder.
if kubectl get deployment rickroll >/dev/null 2>&1; then
  DESIRED="$(kubectl get deployment rickroll -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  READY="$(kubectl get deployment rickroll -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  READY="${READY:-0}"
  DESIRED="${DESIRED:-0}"
  if [ "$DESIRED" -eq 0 ]; then
    # Caso especial: el objeto existe, pero se le han solicitado cero réplicas. El mensaje
    # «ninguna réplica está lista (se necesitan 0)» sonaría a disparate.
    fail "aplicación detenida — se han solicitado 0 réplicas" \
         "recupera una réplica: kubectl scale deployment rickroll --replicas=1"
  elif [ "$READY" -ge 1 ]; then
    ok "aplicación desplegada, ${READY} de ${DESIRED} réplicas listas"
    # Un despliegue atascado no tumba el servicio: la réplica antigua sigue funcionando, y
    # readyReplicas se queda en uno. Sin esta comprobación el participante se va con una marca
    # verde y un deployment atascado para siempre en ErrImagePull.
    # Miramos las réplicas en sí, no solo ProgressDeadlineExceeded: el plazo
    # salta a los diez minutos, mientras que el script se ejecuta de inmediato. La réplica antigua
    # sigue funcionando mientras tanto, readyReplicas se queda en uno, y sin esta comprobación el participante
    # se va con una marca verde y un deployment atascado en ImagePullBackOff.
    STUCK="$(kubectl get pods -l app=rickroll \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
      | awk '$2=="ImagePullBackOff" || $2=="ErrImagePull" || $2=="CrashLoopBackOff" || $2=="CreateContainerConfigError" {print $1" ("$2")"}')"
    PROG_REASON="$(kubectl get deployment rickroll \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null)"
    if [ -n "$STUCK" ] || [ "$PROG_REASON" = "ProgressDeadlineExceeded" ]; then
      fail "el despliegue está atascado: la réplica nueva no se levanta, solo funciona la antigua" \
           "mira kubectl get pods -l app=rickroll — normalmente la imagen no se descargó; restaura un estado funcional: kubectl apply -f rickroll.yaml"
      evidence "Réplicas que no arrancan" "${STUCK:-causa en el estado del Deployment: $PROG_REASON}"
    fi
  else
    fail "aplicación creada, pero ninguna réplica está lista (se necesitan ${DESIRED})" \
         "mira kubectl get pods -l app=rickroll y kubectl describe deployment rickroll"
    evidence "Estado de los pods" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
  fi
else
  fail "no se ha encontrado ningún Deployment llamado rickroll" \
       "aplica el manifiesto: kubectl apply -f rickroll.yaml"
fi

# --- ajustes y página -------------------------------------------------------
# Ambos ConfigMap los crea el mismo fichero que la aplicación, así que solo pueden
# desaparecer junto con ella o por un borrado manual. Los comprobamos por separado para que, cuando
# la página se rompa, el participante vea de inmediato qué falta exactamente: sin rickroll-conf
# nginx no sustituirá el nombre del pod, y sin rickroll-page-v1 no habrá nada con lo que comparar
# la segunda versión en el lab 4 ni un lugar al que volver.
for cm in rickroll-conf rickroll-page-v1; do
  if kubectl get configmap "$cm" >/dev/null 2>&1; then
    ok "ajustes en su sitio: ConfigMap ${cm}"
  else
    fail "no se ha encontrado el ConfigMap ${cm}" \
         "lo crea el mismo fichero: kubectl apply -f rickroll.yaml"
  fi
done

# --- dirección estable ------------------------------------------------------
if kubectl get service rickroll >/dev/null 2>&1; then
  # Un Service sin endpoints es una avería típica y desapercibida: el objeto existe,
  # pero las etiquetas de los pods no coincidieron con el selector, y tras la dirección no hay nada.
  EPS="$(kubectl get endpoints rickroll -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
  EPS_N="$(printf '%s' "$EPS" | wc -w | tr -d ' ')"
  if [ "${EPS_N:-0}" -ge 1 ]; then
    ok "la dirección estable funciona, réplicas tras ella: ${EPS_N}"
    evidence "Direcciones tras el servicio" "$EPS"
  else
    fail "el Service rickroll existe, pero no hay ninguna réplica tras él" \
         "normalmente la causa es que las etiquetas del pod no coincidieron con el selector del servicio — comprueba app: rickroll"
  fi
else
  fail "no se ha encontrado ningún Service llamado rickroll" \
       "lo crea el mismo fichero: kubectl apply -f rickroll.yaml"
fi

# --- lo principal: la página se sirve de verdad -----------------------------
# Es la comprobación para la que se montó todo. Todas las anteriores solo dicen que los objetos
# del clúster están descritos correctamente; esta — que el usuario recibe la página. La petición va
# DESDE DENTRO del clúster, con un pod de un solo uso: desde fuera la dirección rickroll no existe, y
# port-forward aquí probaría tu VM, no el clúster.
# Pedimos varias veces: con varias réplicas tras el servicio una sola muestra
# puede no alcanzar la sustituida, y la comprobación se pone verde con contenido ajeno.
BODY="$(in_cluster_curl_many 'http://rickroll/' 8)"
# El marcador debe aparecer EXACTAMENTE UNA VEZ por página, de lo contrario el contador de respuestas miente:
# «Never Gonna Give You Up» está tanto en <title> como en <h1>, y daba una duplicación.
ANSWERS="$(printf '%s' "$BODY" | grep -c 'вас обслужил под')"
TOTAL_LINES="$(printf '%s' "$BODY" | grep -c '<title>')"
if [ "${ANSWERS:-0}" -ge 1 ] && [ "${ANSWERS:-0}" -eq "${TOTAL_LINES:-0}" ]; then
  ok "la aplicación responde por HTTP y sirve su página (${ANSWERS} peticiones comprobadas)"
elif [ "${ANSWERS:-0}" -ge 1 ]; then
  fail "tras el servicio no responde solo tu aplicación: tu página llegó ${ANSWERS} veces de ${TOTAL_LINES}" \
       "alguien más lleva la etiqueta app=rickroll — mira kubectl get pods -l app=rickroll y elimina lo sobrante"
else
  fail "la aplicación no sirvió la página esperada" \
       "compruébalo a mano: kubectl port-forward svc/rickroll 8080:80, luego abre http://localhost:8080"
  evidence "Qué llegó en lugar de la página" "$(printf '%s' "$BODY" | head -20)"
fi

# --- sustitución del nombre del pod -----------------------------------------
# Es para esto para lo que se hizo el lab: el nombre en la página debe coincidir con el pod real.
SERVED_BY="$(printf '%s' "$BODY" | grep -o '<b>[^<]*</b>' | head -1 | sed 's/<[^>]*>//g')"
# Tomamos los pods gestionados por el ReplicaSet de la aplicación, y NO todo lo que lleve la
# etiqueta app=rickroll. De lo contrario un pod ajeno con esa etiqueta acaba en la lista de los «reales»
# y se confirma a sí mismo — comprobado, así pasaba la comprobación un impostor.
REAL_PODS="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
STRAY="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | awk '$2!="ReplicaSet" {print $1}')"
if [ -n "$STRAY" ]; then
  fail "pods ajenos llevan la etiqueta app=rickroll — entrarán en el balanceo de carga" \
       "elimina lo sobrante: $(printf '%s' "$STRAY" | tr '\n' ' ')"
  evidence "Pods ajenos bajo la etiqueta de la aplicación" "$STRAY"
fi

if [ -z "$SERVED_BY" ]; then
  fail "en la página no hay nombre de pod" \
       "comprueba que se sustituyó el ConfigMap rickroll-conf — tiene la línea sub_filter '__POD__' '\$hostname'"
elif [ "$SERVED_BY" = "__POD__" ]; then
  fail "el nombre del pod no se sustituyó — en la página quedó el marcador __POD__" \
       "nginx no aplicó sub_filter: comprueba que el volumen con los ajustes está montado en /etc/nginx/conf.d"
elif printf '%s' "$REAL_PODS" | grep -qx "$SERVED_BY"; then
  ok "el nombre del pod se sustituye y coincide con una réplica realmente en marcha: ${SERVED_BY}"
  evidence "Quién sirvió la petición" "$SERVED_BY"
  evidence "Réplicas en marcha" "$REAL_PODS"
else
  fail "la página nombra al pod «${SERVED_BY}», pero no existe tal pod en el clúster" \
       "puede que la réplica se recreara entre la petición y la comprobación — ejecuta el script otra vez"
fi

# --- la prueba de disponibilidad está configurada ---------------------------
# Sin ella el lab sobre el despliegue de versiones tendrá parada, y el participante pensará que mentimos.
PROBE_PATH="$(kubectl get deployment rickroll \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE_PATH" ]; then
  ok "la prueba de disponibilidad está configurada (${PROBE_PATH}) — la actualización transcurrirá sin parada"
else
  warn "la aplicación no tiene prueba de disponibilidad" \
       "el lab 4 sobre actualizaciones sin parada dará errores en una aplicación así — restaura readinessProbe desde rickroll.yaml"
fi

finish
