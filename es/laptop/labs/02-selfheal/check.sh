#!/usr/bin/env bash
# Comprobación del lab 2: autorreparación.
#
# Comprobamos no «se escribieron los comandos», sino el estado del clúster tras el lab: la aplicación
# vuelve a atender peticiones a través del Service, devuelve el nombre de su réplica, y ese nombre pertenece
# a un pod realmente en ejecución. Además buscamos rastros de que las réplicas se recrearon.
#
# El script no borra ni crea nada, salvo un pod de un solo uso para comprobar la
# disponibilidad del servicio desde dentro del clúster — se elimina a sí mismo.

LAB_NAME="02-selfheal"
LAB_TITLE="Lab 2 · Matar un pod y ver qué pasa"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

APP=rickroll

# RFC3339 de kubectl (siempre UTC con Z) a segundos unix. Vía python3, porque
# BSD date en macOS y GNU date en Linux analizan las fechas de forma distinta, y python está en todas partes
# donde funciona lib.sh.
_epoch() {
  python3 -c 'import sys,datetime as d;print(int(d.datetime.strptime(sys.argv[1],
"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=d.timezone.utc).timestamp()))' "$1" 2>/dev/null
}

# --- la aplicación existe siquiera -----------------------------------------
DEP_TS="$(kubectl get deployment "$APP" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"

if [ -z "$DEP_TS" ]; then
  fail "la aplicación ${APP} no está en el clúster" \
       "al final del lab había que restaurarla: kubectl apply -f ../01-deploy/rickroll.yaml"
  evidence "Qué hay en el namespace" "$(kubectl get deployment,rs,pods 2>/dev/null)"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

if [ "${HAVE:-0}" -ge 1 ] && [ "$HAVE" = "$WANT" ]; then
  ok "aplicación ${APP} restaurada: réplicas listas ${HAVE} de ${WANT}"
else
  fail "réplicas listas ${HAVE} de las ${WANT} solicitadas" \
       "mire kubectl describe deployment ${APP} y kubectl get pods -l app=${APP}"
fi
evidence "Estado de la aplicación" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- la cadena Deployment -> ReplicaSet -> Pod -----------------------------
# El sentido del lab es que la réplica la devuelve el ReplicaSet, no «el clúster en general».
# Si el propietario del pod resulta no ser un ReplicaSet, el participante levantó el pod a mano,
# y no verá la autorreparación.
# Contamos los pods por nombre, en lugar de recopilar los tipos únicos de propietarios: un pod sin
# ownerReferences hace que jsonpath devuelva una cadena vacía, `sort -u` la colapsa en un elemento
# invisible, y `*ReplicaSet*` coincide mientras al menos un pod esté gestionado por un ReplicaSet.
# Por eso un pod ajeno, levantado a mano, pasaba la comprobación inadvertido.
PODS_TOTAL="$(kubectl get pods -l app=${APP} --no-headers 2>/dev/null | grep -c . )"
PODS_BY_RS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -c . )"
OWNER_KINDS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | sort -u | tr '\n' ' ')"

case "${PODS_TOTAL}:${PODS_BY_RS}" in
  0:*)
    fail "no hay ningún pod con la etiqueta app=${APP}" \
         "restaure la aplicación: kubectl apply -f ../01-deploy/rickroll.yaml"
    ;;
  *:0)
    fail "ningún pod ${APP} está gestionado por un ReplicaSet — no habrá autorreparación" \
         "parece que el pod se levantó a mano (kubectl run). Bórrelo y aplique ../01-deploy/rickroll.yaml"
    ;;
  *)
    if [ "$PODS_TOTAL" -ne "$PODS_BY_RS" ]; then
      fail "la etiqueta app=${APP} la llevan pods ajenos: ${PODS_BY_RS} de ${PODS_TOTAL} están gestionados por un ReplicaSet" \
           "los demás entrarán en el balanceo y devolverán una respuesta ajena — encuéntrelos: kubectl get pods -l app=${APP} -o wide"
      evidence "Propietarios de los pods" \
        "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null)"
    else
    ok "las réplicas las gestiona un ReplicaSet — la cadena Deployment → ReplicaSet → Pod está intacta"
    evidence "Quién es propietario de quién" \
      "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null)"
    fi
    ;;
esac

# --- rastros de recreación de réplicas -------------------------------------
# El clúster no guarda pruebas directas de «se mató el pod». Hay dos indirectas, y ambas bastan:
# el pod es notablemente más joven que su Deployment, y en los eventos del ReplicaSet hay más de una creación.
POD_TS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null)"

DEP_E="$(_epoch "$DEP_TS")"
POD_E="$(_epoch "$POD_TS")"

if [ -n "$DEP_E" ] && [ -n "$POD_E" ]; then
  DELTA=$(( POD_E - DEP_E ))
  if [ "$DELTA" -ge 45 ]; then
    ok "la réplica es ${DELTA} s más joven que la aplicación — así que la anterior se eliminó y esta se creó en su lugar"
  else
    warn "la réplica es casi de la misma edad que la aplicación (diferencia ${DELTA} s)" \
         "si restauró la aplicación entera justo al final — es normal; de lo contrario, el paso de borrar el pod no se hizo"
  fi
  evidence "Edad de los objetos" "deployment creado: ${DEP_TS}
pod creado:        ${POD_TS}
diferencia:        ${DELTA} s"
else
  warn "no se pudo comparar la edad del pod y de la aplicación" \
       "se necesita python3 en el PATH; esto no afecta a la aprobación del lab"
fi

# Los eventos viven cerca de una hora, por eso su ausencia no es un fallo, sino una observación.
CREATES="$(kubectl get events \
  --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet \
  --no-headers 2>/dev/null | grep -c "$APP")"
[ -z "$CREATES" ] && CREATES=0

if [ "$CREATES" -ge 2 ]; then
  ok "en los eventos del clúster hay ${CREATES} creaciones de réplica — la autorreparación realmente se disparó"
  evidence "Eventos de creación de réplicas" \
    "$(kubectl get events --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet 2>/dev/null | grep "$APP" | tail -10)"
else
  warn "en los eventos del clúster se ve la creación de réplica solo ${CREATES} vez/veces" \
       "los eventos se guardan cerca de una hora y podrían haber expirado"
fi

# Ninguno de los dos indicios por separado es bloqueante: los eventos viven cerca de una hora,
# y la edad coincide para quien restauró legítimamente la aplicación entera al final del lab.
# Pero si NO se cumple NINGUNO — la réplica no se borró en absoluto, y el lab no está hecho. Sin esta
# combinación el script imprimía «LAB APROBADO» justo tras el lab 1, sin esperar a un solo borrado.
if [ "${DELTA:-0}" -lt 45 ] && [ "$CREATES" -lt 2 ]; then
  fail "no se encontraron rastros de autorreparación: la réplica no se borró" \
       "borre la réplica: kubectl delete pod -l app=${APP} — y ejecute la comprobación en una hora, mientras los eventos sigan vivos"
fi

# --- el servicio realmente atiende -----------------------------------------
# La comprobación principal en esencia: no «el objeto existe», sino «a través del Service llega una página
# y en ella está el nombre de una réplica viva».
BODY="$(in_cluster_curl "http://${APP}/")"

if [ -z "$BODY" ]; then
  fail "el Service ${APP} no devolvió una página desde dentro del clúster" \
       "compruebe los endpoints: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
elif printf '%s' "$BODY" | grep -q '__POD__'; then
  fail "la página se sirve, pero el nombre de la réplica no se sustituyó en ella" \
       "se perdió el ConfigMap rickroll-conf: aplique ../01-deploy/rickroll.yaml por completo"
else
  SERVED="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
  if [ -z "$SERVED" ]; then
    fail "en la respuesta del Service no hay nombre de réplica" \
         "la página no vino de nuestra aplicación — compruebe kubectl get svc ${APP} -o yaml"
  elif kubectl get pod "$SERVED" >/dev/null 2>&1; then
    ok "el Service sirve una página, la atendió la réplica viva ${SERVED}"
    evidence "Respuesta del Service (fragmento)" \
      "$(printf '%s' "$BODY" | grep -o "te atendió el Pod<b>${APP}-[a-z0-9-]*</b>" | head -1)"
  else
    fail "la página la sirvió la réplica ${SERVED}, pero ese pod ya no existe en el clúster" \
         "espere una decena de segundos y ejecute la comprobación de nuevo — probablemente la réplica estaba cambiando justo ahora"
  fi
fi

# --- preparación para el siguiente lab -------------------------------------
if [ "$WANT" = "1" ]; then
  ok "el número de réplicas volvió a uno — el lab 3 empezará desde cero"
else
  warn "ahora hay réplicas solicitadas: ${WANT}" \
       "antes del lab 3 devuelva una: kubectl scale deployment ${APP} --replicas=1"
fi

finish
