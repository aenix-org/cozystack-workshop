#!/usr/bin/env bash
# Comprobación del lab 7: la caché realmente acelera, y se ve en los números.
#
# La comprobación principal aquí es de comportamiento, no estructural. El script toma un
# identificador sin usar, lo solicita dos veces y observa: la primera vez debe ser un fallo de cientos
# de milisegundos, la segunda — un acierto de unidades. Un manifiesto con las variables de entorno
# correctas no pasará esta comprobación si la caché en realidad no responde.
#
# Dos clústeres: KUBECONFIG — tu clúster lab, COZY_KUBECONFIG — el clúster de gestión
# Cozystack, donde vive el servicio gestionado Redis.

# LAB_NAME y LAB_TITLE van a la cabecera del informe. Luego se incluye la biblioteca común
# de comprobaciones: de ella se toman ok / warn / fail / evidence / finish y, sobre todo,
# in_cluster_curl — levanta un pod de un solo uso con curl DENTRO del clúster. Desde dentro,
# no desde el portátil: los servicios del lab no están expuestos hacia fuera, por nombre passes-api
# solo se ve desde el clúster. need_kubeconfig y need_tenant detienen el script de antemano,
# si el acceso o el número de tenant no están definidos, — de lo contrario todas las comprobaciones
# fallarían a la vez y por el informe no se podría entender la causa.
LAB_NAME="07-redis"
LAB_TITLE="Lab 7 · Caché delante de un backend lento"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# Los nombres y direcciones a los que mira toda la comprobación están reunidos en un solo lugar: no
# habrá que buscarlos por el texto del script. COZY_KUBECONFIG se puede redefinir desde fuera,
# si tu acceso al tenant no está en la ubicación por defecto.
APP="passes-api"
HR="hr-legacy"
SVC="http://${APP}.default.svc.cluster.local"
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/workshop}"

# Dos atajos para todo el script: kget se dirige al clúster lab (el que está en KUBECONFIG),
# cozy — al clúster de gestión Cozystack. Los mensajes de error se silencian a propósito:
# la ausencia de un objeto aquí es una situación normal, de la que el script hablará con sus propias
# palabras y con una pista, no con el texto ajeno de kubectl.
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# Extraer un campo del JSON. Sin jq: no está en un macOS pelado, pero python3 está en todas partes
# donde funciona el resto de la biblioteca de comprobaciones.
jfield() {
  python3 -c 'import sys,json
try:
    print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))
except Exception:
    pass' "$1" 2>/dev/null
}

# --- servicio gestionado Redis en el clúster de gestión ----------------------
# Redis no vive en tu clúster lab, sino en un tenant del clúster de gestión: es un
# servicio gestionado, la plataforma lo mantiene ella misma. Los permisos en el tenant son distintos
# para cada uno, por eso ni una denegación de acceso ni la falta de kubeconfig hacen fallar el lab — el
# trabajo de la caché más abajo se comprueba directamente, con peticiones en vivo, y eso es la prueba de verdad.
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "no se encontró el kubeconfig del tenant ${COZY_KUBECONFIG} — no se comprobó el estado de Redis" \
       "indica la ruta: export COZY_KUBECONFIG=~/.kube/workshop"
else
  REDIS_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get redises.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  REDIS_LIST="$(cozy get redises.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$REDIS_ERR" ]; then
    warn "no se pudo ver las aplicaciones Redis en el tenant ${TENANT_NS}" \
         "el rol en el tenant puede no permitir este comando — no es un error del lab; el trabajo de la caché se comprueba más abajo directamente"
  elif [ -z "$REDIS_LIST" ]; then
    fail "en el tenant ${TENANT_NS} no hay ninguna aplicación Redis" \
         "créala en el dashboard: Crear aplicación -> Redis"
  else
    R_NAME="$(printf '%s' "$REDIS_LIST" | awk 'NR==1{print $1}')"
    R_READY="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    R_REPLICAS="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.spec.replicas}')"
    if [ "$R_READY" = "True" ]; then
      ok "el Redis gestionado «${R_NAME}» está listo, copias de datos: ${R_REPLICAS:-por defecto}"
    else
      warn "Redis «${R_NAME}» existe, pero no informa de que esté listo" \
           "mira su estado en el dashboard; tarda de tres a cinco minutos en arrancar"
    fi
    evidence "Redis en el tenant" "$REDIS_LIST"
  fi
fi

# --- el directorio lento está en su sitio y realmente es lento ---------------
# Sin esta comprobación la comparación «antes y después» no significa nada: si el directorio
# responde al instante, no hay nada que acelerar y nada que la caché pueda medir.
HR_RUNNING="$(kget pods -l app=hr-legacy --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$HR_RUNNING" -lt 1 ]; then
  fail "el directorio ${HR} no funciona" \
       "aplica hr-legacy.yaml y mira kubectl describe pod -l app=hr-legacy"
else
  HR_SEC="$(in_cluster_curl "http://${HR}.default.svc.cluster.local/employee?id=1" \
    "-o /dev/null -w %{time_total}")"
  HR_MS="$(python3 -c 'import sys
try: print(int(float(sys.argv[1])*1000))
except Exception: print(-1)' "${HR_SEC:-0}" 2>/dev/null)"
  if [ "${HR_MS:-0}" -ge 300 ] 2>/dev/null; then
    ok "el directorio responde en ${HR_MS} ms — hay algo que acelerar"
    evidence "Latencia del directorio" "${HR_MS} ms por petición /employee"
  elif [ "${HR_MS:-0}" -lt 0 ] 2>/dev/null; then
    fail "el directorio ${HR} no respondió a la petición" \
         "mira kubectl logs -l app=hr-legacy"
  else
    warn "el directorio responde en ${HR_MS} ms, es demasiado rápido para medir" \
         "comprueba que en hr-legacy.yaml estén definidos MODE=hr y HR_DELAY=800ms"
  fi
fi

# --- la aplicación está configurada para la caché ---------------------------
# Analizamos el entorno del contenedor con python, no con jsonpath: los filtros jsonpath sobre
# listas anidadas se comportan de forma distinta en diferentes versiones de kubectl, y nos importa
# que la comprobación funcione igual para todos.
DEPLOY_JSON="$(kget deployment "$APP" -o json)"
readenv() {
  printf '%s' "$DEPLOY_JSON" | python3 -c 'import sys,json
try:
    d = json.loads(sys.stdin.read())
    env = d["spec"]["template"]["spec"]["containers"][0].get("env", [])
except Exception:
    raise SystemExit
want = sys.argv[1]
if want == "--names":
    print("\n".join(e.get("name","") for e in env))
else:
    for e in env:
        if e.get("name") == want:
            print(e.get("value", ""))
            break' "$1" 2>/dev/null
}

ENVS="$(readenv --names)"
REDIS_ADDR="$(readenv REDIS_ADDR)"
TTL="$(readenv CACHE_TTL)"

# Las quejas se procesan por orden — de la más general a la más concreta: no hay aplicación,
# no hay variable, quedó un marcador de posición en vez de la dirección. El orden aquí no es cosmético:
# de lo contrario el participante recibiría el consejo «pon la dirección de Redis» en un momento en que
# todavía no tiene desplegado el propio servicio, y buscaría el error donde no está.
if [ -z "$(kget deployment "$APP" -o name)" ]; then
  fail "en el clúster lab no está la aplicación ${APP}" \
       "aplica passes-api.yaml, poniendo la dirección de tu propio Harbor"
elif [ -z "$REDIS_ADDR" ]; then
  fail "en ${APP} no está definida la variable REDIS_ADDR — la caché está apagada" \
       "aplica el parche: kubectl patch deployment ${APP} --patch-file cache-patch.yaml"
elif printf '%s' "$REDIS_ADDR" | grep -q 'REDIS-ADDR'; then
  fail "en el parche quedó la dirección marcador de posición REDIS-ADDR" \
       "pon la dirección de tu propio Redis, por ejemplo rfrm-redis-cache.${TENANT_NS}.svc.cozy.local"
else
  ok "la aplicación está configurada para la caché en la dirección ${REDIS_ADDR}, tiempo de vida de la entrada ${TTL:-por defecto} s"
fi

# Solo miramos si el nombre de la variable está presente, el valor no lo leemos ni lo imprimimos en ninguna
# parte. El informe del lab la gente se lo reenvía y lo adjunta a los tickets — una contraseña que acabe ahí
# quedará ahí para siempre.
if printf '%s' "$ENVS" | grep -q '^REDIS_PASSWORD$'; then
  ok "la contraseña de Redis llega a la aplicación (valor: <oculto>)"
else
  fail "en ${APP} no está definida la variable REDIS_PASSWORD" \
       "Redis requiere autenticación; crea el secreto redis-password y aplica cache-patch.yaml"
fi

# La ausencia del secreto es una advertencia, no un fallo: la contraseña se puede entregar al pod
# de otra forma. La propiedad que se comprueba aquí es distinta — en el manifiesto hay una referencia,
# no un valor.
if [ -n "$(kget secret redis-password -o name)" ]; then
  ok "el secreto redis-password con la contraseña de Redis existe"
else
  warn "en el clúster no hay secreto redis-password" \
       "créalo: read -rs P && kubectl create secret generic redis-password --from-literal=password=\"\$P\""
fi

# --- comprobación principal: la caché realmente acelera ----------------------
# Tomamos un identificador deliberadamente nuevo, para que la primera petición sea con seguridad un fallo.
PROBE_ID="check$$$RANDOM"
R1="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"
R2="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"

C1="$(printf '%s' "$R1" | jfield cached)"
C2="$(printf '%s' "$R2" | jfield cached)"
T1="$(printf '%s' "$R1" | jfield took_ms)"
T2="$(printf '%s' "$R2" | jfield took_ms)"
MODE="$(printf '%s' "$R2" | jfield cache)"

if [ -z "$C1" ] || [ -z "$C2" ]; then
  fail "el servicio ${APP} no devolvió el JSON esperado" \
       "mira kubectl logs -l app=passes-api; comprueba que la imagen está construida desde el app/ de este lab (tag v2)"
  evidence "Qué respondió el servicio" "primera petición: ${R1:-vacío}
segunda petición: ${R2:-vacío}"
elif [ "$MODE" != "redis" ]; then
  fail "la aplicación informa de que la caché está apagada (cache: ${MODE})" \
       "la variable REDIS_ADDR no llegó a los pods en ejecución — comprueba kubectl rollout status deployment/${APP}"
elif [ "$C1" = "True" ]; then
  warn "la primera petición ya vino de la caché — no hay con qué comparar" \
       "coincidencia improbable de identificador; ejecuta la comprobación otra vez"
elif [ "$C2" != "True" ]; then
  fail "la segunda petición con el mismo identificador volvió a no acertar en la caché" \
       "la aplicación no puede escribir en Redis: mira kubectl logs -l app=passes-api, normalmente ahí hay NOAUTH o un timeout"
  evidence "Respuestas del servicio" "primera:  ${R1}
segunda: ${R2}"
else
  ok "la caché funciona: fallo ${T1} ms, acierto ${T2} ms"
  SPEEDUP="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print(f"{a/b:.0f}" if b > 0 else "más de 1000")
except Exception:
    print("?")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  evidence "Medición en un servicio en vivo" "identificador: ${PROBE_ID}
primera petición (fallo):   ${T1} ms
segunda petición (acierto): ${T2} ms
ganancia: aproximadamente ${SPEEDUP}x
tiempo de vida de la entrada: ${TTL:-por defecto} s"

  # La parte estricta: el acierto debe ser un orden de magnitud más rápido que el fallo. De lo contrario
  # «la caché funciona» solo significa que la clave se escribió, pero no hay beneficio.
  FASTER="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print("yes" if a >= 100 and b * 10 <= a else "no")
except Exception:
    print("no")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  if [ "$FASTER" = "yes" ]; then
    ok "la ganancia es medible: el acierto es aproximadamente ${SPEEDUP}x más rápido que el fallo"
  else
    warn "el acierto en caché no da una ganancia apreciable (${T1} ms frente a ${T2} ms)" \
         "comprueba que el directorio es realmente lento, y que Redis no está en el mismo pod"
  fi
fi

# --- cuántas copias del servicio comparten una misma caché ------------------
# La caché es común para todas las copias — vale la pena verlo en el informe: el acierto pudo venir
# de un pod distinto que el fallo, y eso es correcto.
API_PODS="$(kget pods -l app=passes-api --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$API_PODS" -ge 1 ]; then
  ok "copias del servicio en ejecución: ${API_PODS} (comparten la caché)"
  evidence "Copias del servicio" "$(kget pods -l app=passes-api -o wide)"
else
  fail "no hay ni una sola copia en ejecución de ${APP}" \
       "mira kubectl describe pod -l app=passes-api"
fi

finish
