#!/usr/bin/env bash
# Verificación del lab 0: el clúster de formación está levantado y te has conectado a él.
#
# No comprobamos «el objeto fue creado», sino que el clúster funciona en esencia:
#   1) el clúster lab responde a través de tu archivo de acceso (KUBECONFIG=~/lab.kubeconfig),
#   2) al menos un nodo está en estado Ready,
#   3) los nodos tienen recursos libres para futuras aplicaciones.
# Si COZY_TENANT está definido — adicionalmente comprobamos en el clúster de GESTIÓN que el
# pedido Kubernetes/lab llegó a Ready y que la recolección de métricas está activada (sin ella el lab 14 queda vacío).
#
# Se ejecuta en la máquina virtual, desde la carpeta de este lab:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_TENANT=workshopXX      # para las comprobaciones del lado del tenant (opcional)
#     cd labs/00-cluster && ./check.sh
#
# El script solo lee — no cambia el estado del clúster.
LAB_NAME="00-cluster"
LAB_TITLE="Lab 0 · Tu propio clúster de Kubernetes"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Sin acceso al propio clúster lab no hay nada que comprobar — esta es la principal
# prueba del lab. need_kubeconfig detiene el script con una pista clara,
# si KUBECONFIG no está definido o el clúster no responde.
need_kubeconfig

COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/config}"
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- 1) Conexión al clúster lab ----------------------------------------------
# need_kubeconfig ya se aseguró de que el servidor responde. Registramos esto como un
# resultado aparte y ponemos la versión del servidor en el informe.
KVER="$(server_version)"
ok "el clúster lab responde — el archivo de acceso funciona"
[ -n "$KVER" ] && evidence "Versión del servidor del clúster lab" "$KVER"

# --- 2) Nodos en servicio ----------------------------------------------------
# Contamos cuántos nodos están en estado Ready. Una lista vacía significa que el clúster
# está levantado, pero el grupo de nodos md0 todavía se está desplegando.
NODES_WIDE="$(kubectl get nodes -o wide 2>/dev/null)"
READY_NODES="$(kubectl get nodes \
  -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null \
  | grep -c '^True')"
TOTAL_NODES="$(kubectl get nodes --no-headers 2>/dev/null | grep -c .)"
if [ "${READY_NODES:-0}" -ge 1 ]; then
  ok "nodos en servicio: ${READY_NODES} de ${TOTAL_NODES} en estado Ready"
  [ -n "$NODES_WIDE" ] && evidence "Nodos del clúster" "$NODES_WIDE"
else
  fail "ningún nodo está en estado Ready (nodos en total: ${TOTAL_NODES:-0})" \
       "espera un par de minutos a que el grupo de nodos md0 se despliegue; el estado está en el panel de la aplicación lab, o: kubectl get nodes"
  evidence "Nodos del clúster" "${NODES_WIDE:-sin nodos}"
fi

# --- 3) ¿Hay espacio para futuras aplicaciones? -----------------------------
# allocatable del primer nodo: si no hay recursos, nada más se iniciará.
ALLOC_CPU="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null)"
ALLOC_MEM="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null)"
if [ -n "$ALLOC_MEM" ]; then
  ok "los nodos tienen recursos para las aplicaciones (en el nodo: ${ALLOC_CPU} CPU, $(human_bytes "$ALLOC_MEM") RAM)"
  evidence "Recursos libres del nodo (allocatable)" "cpu: ${ALLOC_CPU}, memory: $(human_bytes "$ALLOC_MEM")"
else
  warn "no se pudieron leer los recursos libres de los nodos" \
       "normalmente es temporal — reintenta en un minuto"
fi

# --- 4) Desde el lado del clúster de gestión (si hay un tenant definido) ------
# No es obligatorio para el lab 0: la conexión al propio clúster de arriba ya lo demostró todo.
# Pero si hay acceso de tenant — confirmamos el pedido y comprobamos la recolección de métricas.
if [ -n "${COZY_TENANT:-}" ]; then
  TENANT_NS="tenant-${COZY_TENANT}"
  if [ ! -r "$COZY_KUBECONFIG" ]; then
    warn "acceso de tenant ${COZY_KUBECONFIG} no encontrado — el pedido del clúster en el clúster de gestión no se comprobó" \
         "esto no es un fallo del lab; la ruta se define con: export COZY_KUBECONFIG=~/.kube/config"
  else
    LAB_READY="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$LAB_READY" = "True" ]; then
      ok "en el clúster de gestión el pedido Kubernetes/lab está en estado Ready"
    elif [ -n "$LAB_READY" ]; then
      warn "el pedido Kubernetes/lab aún no está Ready (actualmente: ${LAB_READY})" \
           "el clúster ya responde, la plataforma todavía lo está reconciliando al estado deseado; mira: kubectl --kubeconfig ~/.kube/config -n ${TENANT_NS} get kubernetes.apps.cozystack.io lab"
    else
      warn "no se encontró el pedido Kubernetes/lab en el tenant ${TENANT_NS}" \
           "si nombraste el clúster de otra forma — sustituye tu propio nombre; o el rol en el tenant no permite este comando (no es un error del lab)"
    fi
    # Recolección de métricas: el lab 14 se apoya en datos que se acumulan desde el momento en que se activa.
    MON="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.spec.addons.monitoringAgents.enabled}')"
    if [ "$MON" = "true" ]; then
      ok "la recolección de métricas está activada (se necesitará en el lab 14)"
    elif [ -n "$LAB_READY" ]; then
      warn "la recolección de métricas está desactivada — el lab 14 quedará sin datos" \
           "para activarla: panel → aplicación lab → Addons → Monitoring agents (las métricas no aparecerán retroactivamente)"
    fi
  fi
else
  warn "COZY_TENANT no está definido — las comprobaciones del lado del clúster de gestión se omiten" \
       "no es obligatorio para el lab 0; para activarlas: export COZY_TENANT=workshopXX"
fi

finish
