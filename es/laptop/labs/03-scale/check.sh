#!/usr/bin/env bash
# Verificación de la práctica 3: autoescalado.
#
# Verificamos no que «hpa.yaml se aplicó», sino que el mecanismo está vivo y es capaz de tomar decisiones:
#   - el contenedor tiene requests.cpu, de lo contrario no hay base sobre la cual calcular el porcentaje;
#   - el HPA existe y apunta exactamente a nuestro Deployment;
#   - el rango está definido con sentido (maxReplicas mayor que uno, de lo contrario no hay hacia dónde crecer);
#   - las métricas se recolectan REALMENTE: en el estado hay un número, no <unknown>;
#   - el escalado ya se activó, es decir, la carga realmente se aplicó.
#
# El script no cambia nada. Se levanta un pod de un solo uso únicamente para verificar
# que Fortio responde desde dentro del clúster, y se elimina a sí mismo.
#
# Se ejecuta en el portátil, desde la carpeta de esta práctica, usando el acceso al clúster de formación `lab`
# (no al tenant del clúster de gestión):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/03-scale && ./check.sh
# La variable COZY_TENANT no hace falta aquí: toda la práctica transcurre dentro del clúster `lab`.
#
# Ejecutar ANTES de la limpieza. Parte de las verificaciones se apoya en rastros del crecimiento ya ocurrido,
# y estos viven junto con el objeto HPA: si lo eliminas, no quedará nada con qué demostrarlo.

# Van al encabezado del informe y al nombre del archivo report-<práctica>-<fecha>.md junto al script.
LAB_NAME="03-scale"
LAB_TITLE="Práctica 3 · Carga y autoescalado"
# Biblioteca común: ok / fail / warn / evidence / finish, consultas desde dentro del clúster,
# escritura del informe. La ruta se calcula desde la ubicación del propio script, no desde el directorio actual.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Sin KUBECONFIG kubectl busca un clúster en el portátil y lo vuelca todo en un solo error
# en el que no se distingue la causa real. Nos detenemos de inmediato.
need_kubeconfig

# Los nombres se llevan a variables para que la coincidencia entre el nombre de la aplicación y el nombre del HPA
# en esta práctica no parezca el mismo nombre escrito dos veces por accidente.
APP=rickroll
HPA=rickroll

# --- objetivo de escalado en su sitio --------------------------------------
# La aplicación de la práctica 1 es lo que el HPA gestiona. Si no está, todas las
# verificaciones siguientes se derrumban en cascada y el participante recibe una docena de errores en lugar de uno
# claro, por eso este es el único lugar donde el script termina anticipadamente.
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "la aplicación ${APP} no está en el clúster — no hay nada que escalar" \
       "despliégala: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi
ok "la aplicación ${APP} está en su sitio"

# --- requests.cpu: sin él el HPA no calcula porcentajes --------------------
# La causa más frecuente de «el HPA no funciona», y por el manifiesto no se ve:
# el objeto se crea correctamente, pero TARGETS queda para siempre en <unknown>.
REQ_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)"
LIM_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null)"

if [ -n "$REQ_CPU" ]; then
  ok "el contenedor tiene requests.cpu = ${REQ_CPU} — hay base para calcular porcentajes"
  evidence "Recursos del contenedor" "requests.cpu: ${REQ_CPU}
limits.cpu:   ${LIM_CPU:-no definido}"
else
  fail "el contenedor ${APP} no tiene requests.cpu definido" \
       "el HPA por Utilization no funciona sin él; vuelve a aplicar ../01-deploy/rickroll.yaml"
fi

# --- el HPA en sí ----------------------------------------------------------
# Verificamos no solo la existencia del objeto, sino también a quién apunta. Un HPA con un error de tipeo
# en scaleTargetRef se crea correctamente y en la lista parece funcional, pero durante toda la práctica
# gestiona una aplicación inexistente.
TARGET_KIND="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.kind}' 2>/dev/null)"
TARGET_NAME="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)"

if [ -z "$TARGET_NAME" ]; then
  fail "en el clúster no hay ningún HorizontalPodAutoscaler con el nombre ${HPA}" \
       "aplícalo: kubectl apply -f hpa.yaml (ejecuta la verificación antes de la limpieza)"
  evidence "Qué hay de autoescalado" "$(kubectl get hpa 2>&1)"
  finish
  exit $?
fi

if [ "$TARGET_KIND" = "Deployment" ] && [ "$TARGET_NAME" = "$APP" ]; then
  ok "el HPA ${HPA} apunta a Deployment/${APP}"
else
  fail "el HPA ${HPA} gestiona el objeto ${TARGET_KIND}/${TARGET_NAME}, no Deployment/${APP}" \
       "corrige scaleTargetRef en hpa.yaml y vuelve a aplicar"
fi

MINR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)"
MAXR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)"
[ -z "$MINR" ] && MINR=1

if [ -n "$MAXR" ] && [ "$MAXR" -gt 1 ] 2>/dev/null; then
  ok "el rango está definido: de ${MINR} a ${MAXR} copias — hay hacia dónde crecer"
else
  fail "el límite superior del rango es ${MAXR:-no definido} — no hay hacia dónde crecer" \
       "en hpa.yaml debe haber maxReplicas mayor que uno"
fi

# --- objetivo por métrica --------------------------------------------------
# Aquí es warn, no fail: la variante con AverageValue (umbral en milinúcleos) también funciona,
# la práctica cubre solo una de las dos. Suspender por eso sería falso.
TGT_TYPE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.type}' 2>/dev/null)"
TGT_VAL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null)"

if [ "$TGT_TYPE" = "Utilization" ] && [ -n "$TGT_VAL" ]; then
  ok "el umbral está definido: ${TGT_VAL}% de requests.cpu (${REQ_CPU:-?})"
else
  warn "el umbral no está definido como porcentaje de requests (tipo: ${TGT_TYPE:-ninguno})" \
       "la práctica cubre la variante Utilization; esto no afecta la funcionalidad"
fi

# --- LO PRINCIPAL: las métricas se recolectan de verdad --------------------
# Justo aquí se ve la diferencia entre «objeto creado» y «el mecanismo funciona».
CUR_UTIL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)"
SCALING_ACTIVE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.status}{end}' 2>/dev/null)"

if [ -n "$CUR_UTIL" ] && [ "$SCALING_ACTIVE" = "True" ]; then
  ok "las métricas se recolectan: carga actual ${CUR_UTIL}% de requests, el HPA toma decisiones"
elif [ "$SCALING_ACTIVE" = "True" ]; then
  ok "el HPA toma decisiones (ScalingActive=True), el valor actual de la métrica aún no se ha entregado"
else
  REASON="$(kubectl get hpa "$HPA" \
    -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.reason}: {.message}{end}' 2>/dev/null)"
  fail "el HPA no recibe métricas — en TARGETS habrá <unknown>, no tiene sobre qué decidir" \
       "los primeros dos minutos tras el apply esto es normal, espera y reintenta; si no pasó — kubectl top pods y kubectl describe hpa ${HPA}"
  evidence "Por qué el HPA no está activo" "${REASON:-causa no indicada en el estado}"
fi

evidence "Estado del HPA" "$(kubectl get hpa "$HPA" 2>/dev/null)"

# --- metrics-server responde directamente ----------------------------------
# Duplica la verificación anterior desde otro ángulo y separa dos fallos distintos:
# «no hay métricas en todo el clúster» y «hay métricas, pero el HPA no llegó a ellas».
# Lo primero lo arregla el administrador del clúster, lo segundo el participante en su manifiesto.
TOP="$(kubectl top pods -l app=${APP} --no-headers 2>&1)"
# `kubectl top` cuando no hay pods imprime «No resources found» y devuelve 0 —
# sin una comprobación explícita de vacío esto daba verde donde no hay métricas en absoluto.
if [ -z "$TOP" ] || printf '%s' "$TOP" | grep -qiE 'error|not available|No resources found'; then
  fail "kubectl top no reporta el consumo de los pods" \
       "en el clúster no hay un metrics-server funcionando — sin él el autoescalado por CPU es imposible"
  evidence "Respuesta de kubectl top" "$TOP"
else
  ok "metrics-server reporta el consumo de los pods de ${APP}"
  evidence "Consumo de las copias" "$TOP"
fi

# --- el escalado realmente se activó ---------------------------------------
# lastScaleTime vive tanto como el propio HPA, por eso la verificación no depende
# de si los eventos del clúster ya expiraron o no.
LAST_SCALE="$(kubectl get hpa "$HPA" -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
CUR_REPL="$(kubectl get hpa "$HPA" -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"

# Una sola marca de tiempo no basta: también se establece al reducir copias, es decir,
# aparece incluso para quien subió las réplicas a mano y dejó que el HPA quitara las de más. Buscamos
# exactamente crecimiento POR CARGA — un evento con el umbral superado.
#
# Y al revés: la marca en sí no siempre vive. En un clúster donde la carga se aplicó hace una hora,
# lastScaleTime puede estar vacío mientras los eventos siguen vivos — por eso los eventos
# se verifican PRIMERO, de lo contrario una práctica completada se suspende falsamente.
SCALE_UP="$(kubectl get events --field-selector involvedObject.name="$HPA" \
  -o jsonpath='{range .items[*]}{.reason}{" "}{.message}{"\n"}{end}' 2>/dev/null \
  | grep -i 'SuccessfulRescale' | grep -ci 'above target')"

if [ "${SCALE_UP:-0}" -ge 1 ]; then
  ok "el HPA subió la cantidad de copias por carga — el evento de umbral superado está presente"
  evidence "Escalado" "eventos de crecimiento: ${SCALE_UP}
lastScaleTime: ${LAST_SCALE:-ninguno}
currentReplicas: ${CUR_REPL:-desconocido}"
elif [ -n "$LAST_SCALE" ]; then
  ok "el HPA cambió la cantidad de copias (última vez: ${LAST_SCALE})"
  evidence "Marca de tiempo del escalado" "lastScaleTime: ${LAST_SCALE}
currentReplicas: ${CUR_REPL:-desconocido}"
else
  fail "no hay rastros de actividad de autoescalado" \
       "aplica carga desde Fortio: URL http://${APP}/, QPS 1200, Connections 80, Duration 90s"
fi

# --- Fortio: necesario en la práctica 4 ------------------------------------
# Ya no tiene relación con la práctica 3 en sí, por eso warn, no fail. La idea es que el
# participante se entere aquí de que el generador ya no está, y no en medio de un despliegue bajo carga,
# cuando detenerse a desplegarlo resultaría inoportuno.
if kubectl get deployment fortio >/dev/null 2>&1; then
  FBODY="$(in_cluster_curl "http://fortio:8080/fortio/")"
  if printf '%s' "$FBODY" | grep -qi 'fortio'; then
    ok "el generador de carga Fortio funciona y responde desde dentro del clúster"
  else
    warn "Fortio está desplegado, pero su interfaz web no respondió" \
         "verifica: kubectl rollout status deployment/fortio y kubectl logs deploy/fortio"
  fi
else
  warn "Fortio no está en el clúster" \
       "si vas a hacer la práctica 4, allí hará falta: kubectl apply -f fortio.yaml"
fi

finish
