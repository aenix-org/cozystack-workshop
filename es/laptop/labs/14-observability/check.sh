#!/usr/bin/env bash
# Verificación del lab 14: la observabilidad realmente funciona.
#
# «El participante miró un gráfico» no se puede verificar, y fingir que sí es deshonesto.
# Por eso comprobamos aquello sin lo cual un gráfico es imposible:
#   1) el agente de recolección de métricas está corriendo en el clúster,
#   2) envía lo que recolecta a tu tenant, y no al vacío,
#   3) la recolección de logs también funciona — sin ella la mitad del lab no tiene sentido,
#   4) hay un rastro de la carga del lab 3 en el clúster que se puede encontrar en los gráficos.

LAB_NAME="14-observability"
LAB_TITLE="Lab 14 · Observabilidad: encuentra tu pico en los gráficos"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

MON_NS=cozy-monitoring

# --- namespace de recolección ------------------------------------------------
# El namespace por sí solo no prueba nada: la plataforma también coloca ahí metrics-server,
# que se instala en cualquier clúster con etcd y no depende del addon. Comprobamos su
# presencia solo para distinguir «clúster no disponible» de «recolección desactivada».
if ! kubectl get ns "$MON_NS" >/dev/null 2>&1; then
  fail "el clúster no tiene el namespace ${MON_NS} — el clúster respondió de forma distinta a la esperada" \
       "activa el addon: dashboard -> Kubernetes -> lab -> editar -> Addons -> Monitoring agents. Ten en cuenta: los registros aparecerán solo a partir de este momento"
  finish
  exit $?
fi

# --- agente de métricas -----------------------------------------------------
VMAGENT_RUNNING="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/ && $3=="Running"' | grep -c . )"
VMAGENT_TOTAL="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/' | grep -c . )"

if [ "$VMAGENT_RUNNING" -ge 1 ]; then
  ok "el agente de recolección de métricas está corriendo (pods vmagent: ${VMAGENT_RUNNING})"
elif [ "$VMAGENT_TOTAL" -ge 1 ]; then
  fail "el agente de recolección de métricas existe pero no está corriendo (${VMAGENT_RUNNING} de ${VMAGENT_TOTAL} en Running)" \
       "revisa la causa: kubectl -n ${MON_NS} describe pod -l app.kubernetes.io/name=vmagent | sed -n '/Events:/,\$p'"
else
  fail "no hay ni un solo pod vmagent en ${MON_NS} — el addon Monitoring agents está desactivado" \
       "actívalo: dashboard -> Kubernetes -> lab -> editar -> Addons -> Monitoring agents. Los registros empezarán a acumularse solo a partir de este momento; el pasado no se puede recuperar"
fi
evidence "Pods de recolección en ${MON_NS}" "$(kubectl get pods -n "$MON_NS" 2>/dev/null)"

# --- adónde van exactamente las métricas ------------------------------------
# Un agente en marcha que escribe al vacío se ve exactamente igual que uno que funciona.
RW_URL="$(kubectl get vmagent -n "$MON_NS" \
  -o jsonpath='{.items[0].spec.remoteWrite[0].url}' 2>/dev/null)"
if [ -n "$RW_URL" ]; then
  case "$RW_URL" in
    *tenant-*)
      TARGET_NS="$(printf '%s' "$RW_URL" | sed -n 's|.*vminsert-[a-z]*\.\([^.]*\)\..*|\1|p')"
      ok "las métricas se envían al tenant${TARGET_NS:+ (${TARGET_NS})}"
      ;;
    *)
      warn "las métricas se envían a una dirección que no parece específica del tenant" \
           "esto puede estar bien si el ponente configuró un almacenamiento compartido; la dirección está en las evidencias"
      ;;
  esac
  evidence "Adónde se envían las métricas" "$RW_URL"
else
  warn "no se pudo leer la dirección de envío de las métricas" \
       "revísalo a mano: kubectl get vmagent -n ${MON_NS} -o yaml"
fi

# --- recolección de logs ----------------------------------------------------
FB_DESIRED="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $2; exit}')"
FB_READY="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $4; exit}')"
if [ -n "$FB_DESIRED" ] && [ "${FB_READY:-0}" = "$FB_DESIRED" ] && [ "${FB_READY:-0}" != "0" ]; then
  ok "la recolección de logs funciona en todos los nodos (${FB_READY}/${FB_DESIRED})"
elif [ -n "$FB_DESIRED" ]; then
  fail "la recolección de logs no funciona en todos los nodos (${FB_READY:-0} de ${FB_DESIRED})" \
       "revisa: kubectl -n ${MON_NS} get pods | grep fluent-bit — sin ella el paso de búsqueda en los logs no funcionará"
else
  warn "no se encontró el recolector de logs fluent-bit" \
       "la fuente vlogs-generic en Grafana estará vacía; el paso de búsqueda en los logs no se podrá completar"
fi

# --- ¿hay algo que buscar en los gráficos? ----------------------------------
# Las métricas pueden recolectarse perfectamente, pero si no hubo carga, no hay nada que encontrar.
if kubectl get hpa rickroll >/dev/null 2>&1; then
  LAST_SCALE="$(kubectl get hpa rickroll -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
  CUR="$(kubectl get hpa rickroll -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"
  DES="$(kubectl get hpa rickroll -o jsonpath='{.status.desiredReplicas}' 2>/dev/null)"
  if [ -n "$LAST_SCALE" ]; then
    ok "existe un rastro de carga: el autoescalado se activó (última vez ${LAST_SCALE})"
    evidence "Estado del autoescalado" "$(kubectl get hpa rickroll 2>/dev/null)
última activación: ${LAST_SCALE}
réplicas actuales: ${CUR:-?}, deseadas: ${DES:-?}"
  else
    warn "el autoescalado está configurado pero nunca se activó" \
         "no encontrarás el escalón de crecimiento de réplicas; repite la carga del lab 3 con el generador fortio"
  fi
else
  warn "el clúster no tiene ningún HorizontalPodAutoscaler llamado rickroll" \
       "los pasos con gráficos de este lab dependen del lab 3; sin él solo encontrarás el pico de CPU, pero no el escalón"
fi

# --- las propias métricas de la aplicación ----------------------------------
# Indirecto, pero sustancial: si los pods de la aplicación están vivos, su consumo está en los gráficos.
APP_PODS="$(kubectl get pods -l app=rickroll --no-headers 2>/dev/null | grep -c . )"
if [ "${APP_PODS:-0}" -ge 1 ]; then
  ok "los pods de la aplicación están en su sitio (${APP_PODS}) — su consumo se ve en los gráficos"
  evidence "Pods de la aplicación" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
else
  warn "no hay pods de la aplicación rickroll en el clúster" \
       "las métricas históricas del momento del lab 3 se conservan igualmente; solo ajusta ese rango de tiempo en Grafana"
fi

# --- dónde encontrar Grafana ------------------------------------------------
# No es una verificación, sino una ayuda: la dirección de Grafana es lo que más tardan en buscar los participantes.
: "${COZY_KUBECONFIG:=$HOME/.kube/workshop}"
if [ -n "${COZY_TENANT:-}" ] && [ -r "$COZY_KUBECONFIG" ]; then
  TNS="tenant-${COZY_TENANT}"
  MON_TARGET="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get ns "$TNS" \
    -o jsonpath='{.metadata.labels.namespace\.cozystack\.io/monitoring}' 2>/dev/null)"
  if [ -n "$MON_TARGET" ]; then
    GRAF_HOST="$(kubectl --kubeconfig "$COZY_KUBECONFIG" -n "$MON_TARGET" get ingress \
      -o jsonpath='{range .items[*]}{.spec.rules[0].host}{"\n"}{end}' 2>/dev/null \
      | grep '^grafana\.' | head -1)"
    if [ -n "$GRAF_HOST" ]; then
      ok "Grafana para tus métricas: https://${GRAF_HOST}"
      evidence "Grafana" "https://${GRAF_HOST}
las métricas del tenant ${TNS} se almacenan en el namespace ${MON_TARGET}"
    else
      warn "el monitoreo de tu tenant vive en ${MON_TARGET}, pero no se pudo leer la dirección de Grafana" \
           "si ${MON_TARGET} no es tu namespace, entonces Grafana es compartida: pide la dirección al ponente"
      evidence "Monitoreo del tenant" "namespace con monitoreo: ${MON_TARGET}"
    fi
  else
    warn "no se pudo determinar adónde van las métricas del tenant ${TNS}" \
         "pide la dirección de Grafana al ponente o encuéntrala en el dashboard: aplicación Monitoring -> Ingress"
  fi
else
  warn "la dirección de Grafana no está determinada" \
       "define COZY_TENANT y COZY_KUBECONFIG, y el script la encontrará solo; esto no afecta a la aprobación del lab"
fi

finish
