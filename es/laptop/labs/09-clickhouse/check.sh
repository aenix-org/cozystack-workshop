#!/usr/bin/env bash
# Comprobación del lab 9: ClickHouse guarda un registro de pases de entrada y a partir de él se calcula un informe.
#
# No comprobamos «el servicio fue creado», sino lo esencial: la tabla existe, al menos un millón de filas,
# los datos son variados y con picos pronunciados, el informe mensual se calcula en
# milisegundos, y una consulta de una sola columna lee una fracción pequeña de la tabla — es decir,
# el almacenamiento columnar funciona, no solo se afirma.
#
# Ejecución (en cada nueva ventana de terminal las variables se definen de nuevo):
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # tu propio número en lugar de XX
#   export CH_PASSWORD='contraseña del usuario analyst'
#   cd labs/09-clickhouse && ./check.sh
#
# La contraseña no se imprime ni acaba en el informe.
# El script levanta pods de un solo uso con curl, por eso tarda alrededor de un minuto.

# El nombre y el título los necesita la biblioteca común: con ellos firma el informe-artefacto.
# En lib.sh están ok/fail/warn/evidence/finish y las comprobaciones del entorno de abajo — para que
# quince scripts de comprobación impriman de forma uniforme, y no cada uno a su manera.
LAB_NAME="09-clickhouse"
LAB_TITLE="Lab 9 · Analítica sobre un millón de filas"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Ambas comprobaciones detienen el script con un mensaje claro si no está definido el archivo de acceso
# al clúster o el número de tenant. Sin ellos, más adelante llovería con errores de kubectl.
need_kubeconfig
need_tenant

# El participante define COZY_TENANT como `workshop07`, mientras que el namespace se llama
# `tenant-workshop07`. Aceptamos ambas escrituras.
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# Los nombres por defecto son los mismos que en el lab. La forma ${X:-valor} significa «tomar la
# variable de entorno, y si no existe, sustituir el valor»: si le pusiste otro nombre a la aplicación
# — ejecuta como CH_APP=nombre ./check.sh, no hace falta editar el script.
# La dirección es interna, desde el propio clúster: 8123 — el puerto de la interfaz HTTP de ClickHouse.
CH_APP="${CH_APP:-analytics}"
CH_USER="${CH_USER:-analyst}"
CH_TABLE="${CH_TABLE:-passes}"
CH_HOST="chendpoint-clickhouse-${CH_APP}.${NS}.svc.cozy.local:8123"
CH_URL="http://${CH_HOST}/"

evidence "Dirección de ClickHouse" "$CH_URL"

# --- 1. ¿responde el servicio siquiera? -------------------------------------
# /ping no requiere contraseña, por eso esta es la primera y más barata comprobación:
# separa «no hay conexión» de «hay conexión, contraseña incorrecta».
PING="$(in_cluster_curl "${CH_URL}ping")"
if printf '%s' "$PING" | grep -qi 'ok'; then
  ok "ClickHouse responde en la dirección interna del tenant"
else
  fail "ClickHouse no responde en la dirección ${CH_HOST}" \
       "comprueba el número de tenant en COZY_TENANT y el nombre de la aplicación (por defecto 'analytics'; si no, CH_APP=nombre ./check.sh); en el panel la aplicación debe estar en estado listo"
  finish
  exit $?
fi

# Todo lo que sigue requiere iniciar sesión en la base de datos. Sin contraseña el script no adivina ni
# se calla, sino que dice honestamente que el contenido de la base no se comprobó, y termina el informe: de lo
# contrario el participante creería que la comprobación fue superada.
if [ -z "${CH_PASSWORD:-}" ]; then
  fail "no está definida la variable CH_PASSWORD, el contenido de la base no se comprobó" \
       "export CH_PASSWORD='contraseña del usuario ${CH_USER}' y ejecuta el script de nuevo; la contraseña se ve en el panel, secreto clickhouse-${CH_APP}-credentials"
  finish
  exit $?
fi

# Ejecutar SQL desde la entrada estándar y devolver la respuesta.
# Una función aparte, no in_cluster_curl: la consulta va en el cuerpo del POST, y el cuerpo
# necesita entrada estándar, que la función común no tiene.
# La contraseña entra en el pod como variable de entorno desde un Secret temporal, no como argumento:
# todo lo que acaba en args es visible para cualquiera con `get pods`, queda en etcd y aparece en el audit
# log. El propio lab habla de esto — comprobarlo con un script que hace lo contrario
# sería un doble estándar.
ch_query() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "CH_USER=${CH_USER}
CH_PASSWORD=${CH_PASSWORD}
CH_URL=${CH_URL}" \
    sh -c 'curl -sS --max-time 90 -u "$CH_USER:$CH_PASSWORD" --data-binary @- "$CH_URL?default_format=TSV"'
}

# Extraer un número del bloque statistics de una respuesta en formato JSON.
chstat() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
key = sys.argv[1]
src = d.get("statistics", {}) if key in ("elapsed",) else d
val = src.get(key, d.get("statistics", {}).get(key))
if val is None:
    sys.exit(1)
print(val)
' "$1" 2>/dev/null
}

# --- 2. la tabla existe -----------------------------------------------------
EXISTS="$(printf 'EXISTS TABLE %s' "$CH_TABLE" | ch_query | tr -d '[:space:]')"
if [ "$EXISTS" = "1" ]; then
  ok "la tabla ${CH_TABLE} existe"
else
  if printf '%s' "$EXISTS" | grep -qi 'auth'; then
    fail "ClickHouse no aceptó la contraseña del usuario ${CH_USER}" \
         "verifica la contraseña en el panel: aplicación ${CH_APP} → Secrets → clickhouse-${CH_APP}-credentials"
  else
    fail "la tabla ${CH_TABLE} no existe" \
         "créala: ch < 01-schema.sql (análisis del esquema — en el README)"
  fi
  finish
  exit $?
fi

# --- 3. cuántos datos hay y qué tan variados son ----------------------------
# Una sola consulta en lugar de seis: cada llamada a ch_query levanta un pod, y seis
# pods seguidos convertirían la comprobación en una espera de un minuto sin motivo.
STATS="$(ch_query <<SQL
SELECT
    (SELECT count() FROM ${CH_TABLE}),
    (SELECT uniqExact(entrance) FROM ${CH_TABLE}),
    (SELECT uniqExact(pass_type) FROM ${CH_TABLE}),
    (SELECT uniqExact(toStartOfMonth(created_at)) FROM ${CH_TABLE}),
    (SELECT max(c) FROM (SELECT toHour(created_at) AS h, count() AS c FROM ${CH_TABLE} GROUP BY h)),
    (SELECT min(c) FROM (SELECT toHour(created_at) AS h, count() AS c FROM ${CH_TABLE} GROUP BY h)),
    (SELECT sum(data_uncompressed_bytes) FROM system.columns
      WHERE database = currentDatabase() AND table = '${CH_TABLE}')
SQL
)"

ROWS="$(printf '%s' "$STATS" | awk 'NR==1{print $1}')"
UNIQ_ENT="$(printf '%s' "$STATS" | awk 'NR==1{print $2}')"
UNIQ_TYPE="$(printf '%s' "$STATS" | awk 'NR==1{print $3}')"
UNIQ_MONTH="$(printf '%s' "$STATS" | awk 'NR==1{print $4}')"
PEAK_MAX="$(printf '%s' "$STATS" | awk 'NR==1{print $5}')"
PEAK_MIN="$(printf '%s' "$STATS" | awk 'NR==1{print $6}')"
TABLE_BYTES="$(printf '%s' "$STATS" | awk 'NR==1{print $7}')"

for v in ROWS UNIQ_ENT UNIQ_TYPE UNIQ_MONTH PEAK_MAX PEAK_MIN TABLE_BYTES; do
  eval "val=\$$v"
  case "$val" in
    ''|*[!0-9]*) eval "$v=0" ;;
  esac
done

if [ "$ROWS" -ge 1000000 ]; then
  ok "la tabla tiene ${ROWS} filas — se generó un millón"
else
  fail "la tabla tiene ${ROWS} filas, se esperaba un millón" \
       "ejecuta el generador: ch < 02-generate.sql (análisis del generador — en el README)"
fi

if [ "$UNIQ_ENT" -ge 2 ] && [ "$UNIQ_TYPE" -ge 3 ] && [ "$UNIQ_MONTH" -ge 3 ]; then
  ok "los datos son variados: entradas ${UNIQ_ENT}, tipos de pase ${UNIQ_TYPE}, meses ${UNIQ_MONTH}"
else
  fail "los datos son monótonos: entradas ${UNIQ_ENT}, tipos ${UNIQ_TYPE}, meses ${UNIQ_MONTH}" \
       "con esos datos el informe no mostrará nada; regenera: TRUNCATE TABLE ${CH_TABLE}, luego ch < 02-generate.sql"
fi

if [ "$PEAK_MIN" -gt 0 ] && [ "$PEAK_MAX" -ge $((PEAK_MIN * 2)) ]; then
  ok "los datos tienen picos horarios pronunciados (la hora más cargada frente a la más tranquila — no menos del doble)"
  evidence "Distribución por horas" "máximo por hora: ${PEAK_MAX}
mínimo por hora: ${PEAK_MIN}"
else
  warn "no se ven picos horarios: máximo ${PEAK_MAX}, mínimo ${PEAK_MIN}" \
       "el informe «cuándo son los picos» no tiene sentido con esos datos; comprueba que el generador se completó por entero"
fi

# --- 4. el informe mensual se calcula rápido --------------------------------
REPORT="$(ch_query <<SQL
SELECT toStartOfMonth(created_at) AS month, count() AS guests
FROM ${CH_TABLE}
GROUP BY month
ORDER BY month
FORMAT JSON
SQL
)"

ELAPSED="$(printf '%s' "$REPORT" | chstat elapsed)"
READ_ROWS="$(printf '%s' "$REPORT" | chstat rows_read)"

if [ -z "$ELAPSED" ]; then
  fail "el informe mensual no se ejecutó" \
       "ejecútalo manualmente: ch < 03-report.sql y mira el texto del error"
else
  MS="$(python3 -c "print(round(float('$ELAPSED') * 1000, 1))" 2>/dev/null)"
  # Mantenemos el umbral cerca de lo que promete el lab. Los antiguos cinco segundos contaban
  # como éxito un informe de cuatro segundos — a pesar de que en la cabecera del lab dice
  # «se calcula en milisegundos». El script no debe confirmar lo que no comprobó.
  FAST="$(python3 -c "print(1 if float('$ELAPSED') < 0.5 else 0)" 2>/dev/null)"
  SLOW="$(python3 -c "print(1 if float('$ELAPSED') > 3 else 0)" 2>/dev/null)"
  if [ "$FAST" = "1" ]; then
    ok "el informe mensual se calculó en ${MS} ms, filas leídas: ${READ_ROWS}"
  elif [ "$SLOW" = "1" ]; then
    fail "el informe mensual tardó ${MS} ms — no es el orden de magnitud del que trata el lab" \
         "un millón de filas en un banco libre cabe en decenas de milisegundos; comprueba que el servicio no esté ocupado con una carga vecina, y repite"
  else
    warn "el informe mensual se calculó en ${MS} ms — más lento de lo esperado, pero dentro de lo razonable" \
         "en un banco ocupado eso pasa; en uno libre semejante informe cabe en decenas de milisegundos"
  fi
  evidence "Informe mensual" "tiempo: ${MS} ms
filas leídas: ${READ_ROWS}"
fi

# --- 5. el almacenamiento columnar funciona, no solo se afirma --------------
# La consulta toca una sola columna pequeña. Si el almacenamiento es columnar, lo leído
# será notablemente menos de lo que pesa toda la tabla.
NARROW="$(ch_query <<SQL
SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON
SQL
)"
NARROW_BYTES="$(printf '%s' "$NARROW" | chstat bytes_read)"
case "$NARROW_BYTES" in
  ''|*[!0-9]*) NARROW_BYTES=0 ;;
esac

# Ambas magnitudes son SIN COMPRIMIR: `bytes_read` en las estadísticas de la consulta es el volumen
# descomprimido, y de system.columns se toma `data_uncompressed_bytes`. Compararlo con
# `data_compressed_bytes` daba una fracción del tamaño en disco e imprimía al participante
# un número incorrecto — en una tabla bien comprimida podía superar el cien por cien.
if [ "$NARROW_BYTES" -gt 0 ] && [ "$TABLE_BYTES" -gt 0 ]; then
  SHARE="$(python3 -c "print(round(100 * $NARROW_BYTES / $TABLE_BYTES))" 2>/dev/null)"
  evidence "Lectura de una sola columna" "bytes leídos: ${NARROW_BYTES}
toda la tabla sin comprimir, bytes: ${TABLE_BYTES}
proporción: ${SHARE}%"
  # Un umbral, no simplemente «menos que el total». Una columna estrecha de siete debería dar unidades
  # de por ciento; «99% en vez de 100%» es formalmente menos pero no prueba nada — y es justamente
  # esa afirmación la que el lab pone en su título.
  if [ "$SHARE" -le 25 ]; then
    ok "la consulta de una sola columna leyó el ${SHARE}% de los datos de la tabla — el almacenamiento columnar funciona"
  elif [ "$NARROW_BYTES" -lt "$TABLE_BYTES" ]; then
    warn "la consulta de una sola columna leyó el ${SHARE}% de los datos de la tabla — menos que el total, pero la ganancia es más modesta de lo esperado" \
         "se esperaban unidades de por ciento; comprueba que la consulta se dirige a una sola columna estrecha, y no a varias"
  else
    warn "la consulta de una sola columna leyó no menos que toda la tabla" \
         "eso pasa en tablas muy pequeñas; comprueba que realmente haya un millón de filas"
  fi
else
  warn "no se pudo medir cuánto leyó la consulta estrecha" \
       "ejecútala manualmente: SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON y mira bytes_read"
fi

# finish imprime el resultado y guarda el informe-artefacto en un archivo; el código de retorno es distinto de cero
# si al menos una comprobación falló.
finish
