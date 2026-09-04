#!/usr/bin/env bash
# Comprobación de la lab 11: la compilación de Android llegó hasta el final, y el APK — hasta el bucket.
#
# Verificamos no «se creó el Job», sino tres afirmaciones distintas, y no son equivalentes entre sí:
#   1) el Job terminó con éxito,
#   2) dentro de él realmente se compiló un APK (BUILD SUCCESSFUL),
#   3) el archivo realmente se fue al almacenamiento de objetos (el marcador APK-UPLOADED).
# Un Job puede terminar con éxito y no compilar nada — si alguien editó el script.
#
# Se ejecuta en la VM, desde la carpeta de esta lab, usando el acceso al clúster de formación `lab`
# (no al tenant en el clúster de gestión — la compilación corre en el clúster):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/11-android && ./check.sh
#
# El script no cambia nada en el clúster — solo lee y envía peticiones HTTP.
# Ejecútalo antes de la limpieza: al eliminar el Job se eliminan también sus logs, y sin los logs
# no queda nada con qué confirmar dos de las tres afirmaciones anteriores.

# Estas dos variables las recoge lib.sh — van a la cabecera del informe y al nombre del
# archivo report-<lab>-<fecha>.md, que el script coloca junto a sí mismo.
LAB_NAME="11-android"
LAB_TITLE="Lab 11 · Compilación de una app móvil en el clúster"
# Biblioteca común de comprobaciones: de aquí vienen ok / fail / warn / evidence / finish,
# la petición desde dentro del clúster y la escritura del informe. La ruta se calcula respecto al lugar
# donde está el propio script, así que ejecutarlo desde cualquier directorio funciona igual.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Nos detenemos de inmediato si KUBECONFIG no está definido. Sin él kubectl busca un clúster
# en la propia VM, no lo encuentra y hace fallar todas las comprobaciones seguidas con el mismo error,
# del que no se ve la causa real.
need_kubeconfig

JOB=propusk-build
SECRET=bucket-creds

# El valor de una clave del secreto. base64 -d no es igual en todas partes (BSD vs GNU),
# así que decodificamos con python — la biblioteca de comprobaciones ya lo necesita.
secret_val() {
  kubectl get secret "$SECRET" -o jsonpath="{.data.$1}" 2>/dev/null \
    | python3 -c 'import sys,base64
d=sys.stdin.read().strip()
print(base64.b64decode(d).decode("utf-8", "replace") if d else "")' 2>/dev/null
}

# --- secreto con acceso al bucket -----------------------------------------
# Verificamos no que el secreto exista, sino que los cuatro campos que contiene estén rellenos.
# El secreto se crea a mano, con cuatro --from-literal seguidos, y el problema más común
# es un valor vacío o ausente: el objeto se crea con éxito, pero la compilación falla
# en el último paso, cuando la compilación ya ha pasado. Más barato averiguarlo ahora.
if kubectl get secret "$SECRET" >/dev/null 2>&1; then
  MISSING=""
  for k in endpoint bucketName accessKey secretKey; do
    [ -z "$(secret_val "$k")" ] && MISSING="$MISSING $k"
  done
  if [ -z "$MISSING" ]; then
    ok "el secreto ${SECRET} está en su sitio, las cuatro claves están rellenas"
    # Los valores de las claves no van al informe — solo los nombres de los campos.
    evidence "Campos del secreto ${SECRET}" "endpoint: $(secret_val endpoint)
bucketName: $(secret_val bucketName)
accessKey: <oculto>
secretKey: <oculto>"
  else
    fail "el secreto ${SECRET} tiene campos sin rellenar:${MISSING}" \
         "recrea el secreto con el comando del README, los valores se toman en el dashboard: Bucket -> builds -> Secrets"
  fi
else
  fail "no hay secreto ${SECRET} en el clúster" \
       "crea el secreto: kubectl create secret generic ${SECRET} --from-literal=endpoint=... (cuatro campos)"
fi

# --- ¿es alcanzable el almacenamiento desde dentro del clúster? ------------
# La causa más común de «el Job falló en el paso cinco» no son las claves, sino que el
# almacenamiento es inalcanzable desde el clúster. Lo comprobamos por separado de la compilación.
# La petición sale de un pod, no de la VM: la VM tiene su propia red y sus propias rutas,
# y su respuesta exitosa no diría nada sobre si la compilación puede llegar allí.
EP="$(secret_val endpoint)"
if [ -n "$EP" ]; then
  # Deliberadamente sin -k: la compilación va al almacenamiento con verificación de certificado, y la comprobación
  # debe fallar en el mismo lugar donde falla el Job, no dar verde con un certificado caducado.
CODE="$(in_cluster_curl "https://${EP}/" "-o /dev/null -w %{http_code}")"
  case "$CODE" in
    2*|3*|4*)
      ok "el almacenamiento ${EP} responde desde dentro del clúster (HTTP ${CODE})"
      evidence "Respuesta del almacenamiento" "GET https://${EP}/ -> HTTP ${CODE}
Los códigos 403 y 404 aquí son normales: una petición anónima a la raíz de S3 debe ser rechazada."
      ;;
    5*)
      warn "el almacenamiento ${EP} responde con error HTTP ${CODE}" \
           "la compilación puede pasar, pero la subida del APK no; avisa al instructor"
      ;;
    *)
      fail "el almacenamiento ${EP} no responde desde dentro del clúster" \
           "revisa el campo endpoint en el secreto: debe ir SIN https:// y sin barra al final"
      ;;
  esac
else
  warn "no compruebo la disponibilidad del almacenamiento" \
       "primero hace falta el secreto ${SECRET} con el campo endpoint"
fi

# --- el Job en sí ----------------------------------------------------------
# Miramos .status.succeeded, no el hecho de que el Job exista: el objeto se crea
# al instante y siempre con éxito, mientras que el éxito de la tarea significa que el pod terminó con código 0.
# El estado del pod se examina por separado, porque «aún en marcha» y «atascado en Pending» son
# noticias distintas para una persona: lo primero significa esperar, lo segundo que esperar es inútil
# y hay que agrandar el nodo.
if ! kubectl get job "$JOB" >/dev/null 2>&1; then
  fail "no hay Job ${JOB} en el clúster" \
       "inicia la compilación: kubectl apply -f android-build.yaml"
else
  SUCCEEDED="$(kubectl get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)"
  FAILED="$(kubectl get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null)"
  DURATION="$(kubectl get job "$JOB" -o jsonpath='{.status.completionTime}' 2>/dev/null)"
  POD_PHASE="$(kubectl get pods -l "job-name=${JOB}" \
    -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)"

  if [ "${SUCCEEDED:-0}" -ge 1 ] 2>/dev/null; then
    ok "el Job ${JOB} terminó con éxito"
    evidence "Job" "$(kubectl get job "$JOB" -o wide 2>/dev/null)
completado: ${DURATION:-desconocido}"
  elif [ "$POD_PHASE" = "Pending" ]; then
    fail "el pod de compilación está atascado en Pending — no arrancó y no arrancará por sí solo" \
         "mira la causa: kubectl describe pod -l job-name=${JOB} | grep -A5 Events; con Insufficient memory agranda el nodo a u1.large — cómo hacerlo está escrito en el README"
    evidence "Eventos del pod de compilación" \
      "$(kubectl describe pod -l "job-name=${JOB}" 2>/dev/null | sed -n '/Events:/,$p' | head -20)"
  elif [ "${FAILED:-0}" -ge 1 ] 2>/dev/null; then
    fail "el Job ${JOB} terminó con error (intentos fallidos: ${FAILED})" \
         "mira las últimas líneas del log: kubectl logs job/${JOB} --tail=40"
    evidence "Cola del log de la compilación fallida" \
      "$(kubectl logs "job/${JOB}" --tail=30 2>/dev/null)"
  else
    fail "el Job ${JOB} aún no ha terminado (estado del pod: ${POD_PHASE:-desconocido})" \
         "la primera compilación tarda desde un par de minutos hasta un cuarto de hora, según la conexión; sigue: kubectl logs -f job/${JOB}"
  fi

  # --- qué ocurrió exactamente dentro -------------------------------------
  # Un Job exitoso por sí mismo no prueba nada más allá de un código de retorno cero.
  # Por eso abrimos el log y buscamos en él dos evidencias distintas: BUILD SUCCESSFUL —
  # que la compilación llegó hasta el final, y la línea marcador APK-UPLOADED, que el script imprime
  # solo después de copiar el archivo al bucket. La segunda es más fuerte que la primera: un APK puede compilarse
  # y quedarse dentro de un pod que está a punto de desaparecer.
  LOGS="$(kubectl logs "job/${JOB}" --tail=-1 2>/dev/null)"
  if [ -z "$LOGS" ]; then
    warn "los logs de la compilación no están disponibles" \
         "el pod de compilación fue eliminado o aún no se ha creado; sin logs no se puede confirmar que el APK realmente se compiló"
  else
    if printf '%s' "$LOGS" | grep -q 'BUILD SUCCESSFUL'; then
      GRADLE_LINE="$(printf '%s' "$LOGS" | grep -m1 'BUILD SUCCESSFUL')"
      ok "el APK realmente se compiló (${GRADLE_LINE})"
    else
      fail "no hay línea BUILD SUCCESSFUL en los logs — la compilación no llegó hasta el final" \
           "busca la primera línea con FAILURE: kubectl logs job/${JOB} | grep -n -m1 -A20 FAILURE"
    fi

    UPLOADED="$(printf '%s' "$LOGS" | grep -m1 '^APK-UPLOADED ' | awk '{print $2}')"
    if [ -n "$UPLOADED" ]; then
      ok "el APK se fue al bucket: ${UPLOADED}"
      evidence "Contenido del bucket tras la compilación" \
        "$(printf '%s' "$LOGS" | sed -n '/5\/5 кладу APK в бакет/,$p' | grep -v '^APK-UPLOADED ' | head -20)"
    else
      fail "el APK se compiló, pero no se fue al bucket" \
           "mira la cola del log: kubectl logs job/${JOB} --tail=20; lo más frecuente es que bucketName tenga la culpa — necesita el nombre largo del dashboard, no 'builds'"
    fi
  fi
fi

# --- ¿tiene el nodo espacio suficiente para tal compilación? ---------------
# No es una sentencia, sino una explicación: si el Job no cupo, la causa casi siempre está aquí.
BIGGEST_MEM="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
  | sort -n | tail -1)"
if [ -n "$BIGGEST_MEM" ]; then
  BIGGEST_H="$(human_bytes "$BIGGEST_MEM")"
  case "$BIGGEST_H" in
    *Gi)
      GB="${BIGGEST_H%Gi}"
      GB_INT="${GB%%.*}"
      if [ "${GB_INT:-0}" -ge 6 ] 2>/dev/null; then
        ok "el nodo más grande ofrece ${BIGGEST_H} de memoria — suficiente para la compilación"
      else
        warn "el nodo más grande ofrece solo ${BIGGEST_H} de memoria" \
             "la compilación pide 4Gi solo para requests; si el Job se queda en Pending, agranda el tipo de nodo a u1.large — cómo, está escrito en el README"
      fi
      ;;
    *)
      warn "los nodos tienen menos de un gigabyte de memoria disponible (${BIGGEST_H})" \
           "una compilación de Android no cabrá ahí, agranda el tipo de nodo — cómo, está escrito en el README"
      ;;
  esac
  evidence "Recursos de los nodos" "$(kubectl get nodes -o wide 2>/dev/null)"
fi

finish
