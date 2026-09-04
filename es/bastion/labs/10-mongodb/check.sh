#!/usr/bin/env bash
# Comprobación del lab 10: en MongoDB hay pases de distintas formas y se hacen búsquedas sobre ellos.
#
# No comprobamos «el servicio está creado», sino el fondo: en la colección hay documentos de las cuatro
# formas, la búsqueda por un campo anidado y dentro de una lista funciona, sobre un campo raro
# hay un índice disperso, el validador de esquema está activado, y no quedan documentos sin tipo.
#
# Ejecución (en cada nueva ventana de terminal las variables se definen de nuevo):
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # tu número en lugar de XX
#   export MONGO_PASSWORD='contraseña del usuario passapp'
#   cd labs/10-mongodb && ./check.sh
#
# La contraseña no se imprime y no acaba en el informe.
# El script levanta pods desechables, por eso tarda alrededor de un minuto.

# El nombre y el título los necesita la biblioteca común: firma con ellos el informe-artefacto.
# En lib.sh están ok/fail/warn/evidence/finish y las comprobaciones de entorno de abajo — para que
# los quince scripts de comprobación impriman igual, y no cada uno a su manera.
LAB_NAME="10-mongodb"
LAB_TITLE="Lab 10 · Almacén de documentos"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Ambas comprobaciones detienen el script con un mensaje claro si no está definido el archivo de acceso
# al clúster o el número de tenant. Sin ellos, más abajo se acumularían errores de kubectl.
need_kubeconfig
need_tenant

# El participante define COZY_TENANT como `workshop07`, mientras que el namespace se llama
# `tenant-workshop07`. Aceptamos ambas escrituras.
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# Los nombres por defecto son los mismos que en el lab. La notación ${X:-valor} significa «tomar
# la variable de entorno, y si no existe, sustituir el valor»: si nombraste la aplicación
# de otra manera — ejecútalo como MONGO_APP=nombre ./check.sh, no hace falta editar el script.
# La dirección es interna, desde dentro del propio clúster; rs0 en el nombre es el conjunto de réplicas en el que
# vive nuestra única copia.
MONGO_APP="${MONGO_APP:-passes}"
MONGO_USER="${MONGO_USER:-passapp}"
MONGO_DB="${MONGO_DB:-passes}"
MONGO_COLL="${MONGO_COLL:-passes}"
MONGO_HOST="mongodb-${MONGO_APP}-rs0.${NS}.svc.cozy.local:27017"

evidence "Dirección de MongoDB" "$MONGO_HOST"

# --- 1. ¿hay conectividad al puerto siquiera? ------------------------------
# MongoDB en su puerto responde a una petición HTTP con una frase clara sobre que
# aquí se accede con un driver, no con un navegador. Con eso basta para distinguir
# «el nombre no se resuelve / el puerto está cerrado» de «hay conectividad, las credenciales no son las correctas».
PROBE="$(in_cluster_curl "http://${MONGO_HOST}/")"
if printf '%s' "$PROBE" | grep -qi 'mongodb'; then
  ok "MongoDB responde en la dirección interna del tenant"
else
  fail "no hay conectividad con MongoDB en la dirección ${MONGO_HOST}" \
       "revisa el número de tenant en COZY_TENANT y el nombre de la aplicación (por defecto 'passes'; si no, MONGO_APP=nombre ./check.sh); en el panel la aplicación debe estar en estado listo"
  finish
  exit $?
fi

# Todo lo que sigue requiere entrar en la base de datos. Sin contraseña el script no adivina ni se calla,
# sino que dice honestamente que el contenido de la base no se comprobó, y termina el informe: de lo contrario
# el participante creería que la comprobación pasó.
if [ -z "${MONGO_PASSWORD:-}" ]; then
  fail "no está definida la variable MONGO_PASSWORD, el contenido de la base no se comprobó" \
       "export MONGO_PASSWORD='contraseña del usuario ${MONGO_USER}' y ejecuta el script de nuevo"
  finish
  exit $?
fi

# La contraseña se codifica en porcentaje: los caracteres @ : / ? # % en ella, de otro modo, rompen la cadena
# de conexión, y la persona recibe un error de análisis poco claro en lugar de «contraseña incorrecta».
_pct() { printf %s "$1" | sed -e 's|%|%25|g' -e 's|@|%40|g' -e 's|:|%3A|g' \
                              -e 's|/|%2F|g' -e 's|?|%3F|g' -e 's|#|%23|g'; }
MONGO_URI="mongodb://${MONGO_USER}:$(_pct "$MONGO_PASSWORD")@${MONGO_HOST}/${MONGO_DB}?authSource=admin&directConnection=true"

# ⚠️ La cadena de conexión contiene la contraseña y se pasa como argumento del pod. Es un compromiso
# deliberado: ver `in_cluster_with_secrets` en check/lib.sh — existe una vía segura, pero
# es incompatible con un --eval multilínea sin sobrecomplicar. El pod vive segundos y
# se elimina solo; la contraseña no acaba en el informe. En scripts de producción no lo hagas así.
#
# Todas las comprobaciones de una sola vez: cada llamada levanta un pod, y diez pods seguidos
# convertirían la comprobación en una espera de varios minutos sin motivo.
# Hacia fuera se entrega una única línea JSON, luego la analiza python.
# `--overrides` con securityContext: sin él el pod no se crearía en un clúster con el perfil
# `restricted`, y el lab fallaría por una razón ajena al participante.
# `--command --` se mantiene: kubectl lo combina con el override, donde solo están definidos los
# campos de seguridad.
# El programa para mongosh. Las comillas dobles dentro de él son seguras: hacia fuera el texto sale
# a través de python, que lo entrecomilla él mismo, y los nombres de la base y la colección se sustituyen
# por las marcas de abajo.
MONGO_EVAL=$(cat <<'JSEOF'

var out = {};
try {
  var c = db.getSiblingDB("__DB__").getCollection("__COLL__");
  out.ok = 1;
  out.total = c.countDocuments({});
  out.types = c.distinct("type").length;
  out.withCar = c.countDocuments({ "car.plate": { $exists: true } });
  out.withArray = c.countDocuments({
    $or: [ { entrances: { $exists: true } }, { members: { $exists: true } } ]
  });
  out.nested = c.countDocuments({ "members.name": { $exists: true } });
  out.typeless = c.countDocuments({ type: { $exists: false } });
  var idx = c.getIndexes();
  out.indexes = idx.map(function (i) { return i.name; });
  out.sparse = idx.filter(function (i) {
    return i.sparse === true || i.partialFilterExpression !== undefined;
  }).map(function (i) { return i.name; });
  var info = db.getSiblingDB("__DB__").getCollectionInfos({ name: "__COLL__" });
  var opts = (info && info[0] && info[0].options) ? info[0].options : {};
  out.validator = opts.validator ? 1 : 0;
  out.validationAction = opts.validationAction || "";
} catch (e) {
  out.ok = 0;
  out.error = String(e.message || e);
}
print(JSON.stringify(out));
JSEOF
)
MONGO_EVAL="${MONGO_EVAL//__DB__/$MONGO_DB}"
MONGO_EVAL="${MONGO_EVAL//__COLL__/$MONGO_COLL}"

# El comando del contenedor se coloca DENTRO del override, en lugar de quedarse fuera en `--command --`.
# kubectl aplica el override como un JSON merge patch, y en él el array containers se reemplaza
# por completo: el `--command` definido fuera no llegaría al pod, y en lugar de mongosh se habría iniciado
# el proceso por defecto de la imagen — es decir, la propia base. Así se hace también en check/lib.sh.
MONGO_SC="$(python3 - "$MONGO_URI" "$MONGO_EVAL" <<'PYEOF'
import json, sys
uri, script = sys.argv[1], sys.argv[2]
print(json.dumps({"spec": {
  "securityContext": {"runAsNonRoot": True, "runAsUser": 999,
                      "seccompProfile": {"type": "RuntimeDefault"}},
  "containers": [{"name": "mongo-check", "image": "mongo:8.0", "stdin": True,
                  "securityContext": {"allowPrivilegeEscalation": False,
                                      "capabilities": {"drop": ["ALL"]}},
                  "command": ["mongosh", "--quiet", uri, "--eval", script]}]}}))
PYEOF
)"

SUMMARY="$(kubectl run "mongo-check" --rm -i --restart=Never --quiet \
  --pod-running-timeout=90s --overrides="$MONGO_SC" \
  --image=mongo:8.0 </dev/null 2>/dev/null | tr -d '\r' | grep '^{' | tail -1)"

# Extraer un campo de la línea JSON que imprimió mongosh. Las listas se unen con
# coma, para poder mostrarlas al participante tal cual.
mget() {
  printf '%s' "$SUMMARY" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
v = d.get(sys.argv[1])
if v is None:
    sys.exit(1)
print(v if not isinstance(v, list) else ", ".join(str(x) for x in v))
' "$1" 2>/dev/null
}

# Lo mismo, pero para números: cualquier valor inesperado se convierte en 0, de lo contrario la comparación
# de abajo fallaría con un error aritmético en lugar de un FAIL claro.
num() {
  local v
  v="$(mget "$1")"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

# Si no hay respuesta alguna o mongosh informó de un error — no hay nada más que comprobar.
# El fallo de autenticación se separa de los demás errores: tiene su propia causa frecuente —
# un authSource=admin olvidado, y la pista debe llevar exactamente a ella.
if [ -z "$SUMMARY" ] || [ "$(mget ok)" != "1" ]; then
  ERR="$(mget error)"
  case "$ERR" in
    *[Aa]uthentication*)
      fail "MongoDB no aceptó las credenciales del usuario ${MONGO_USER}" \
           "revisa la contraseña y que la cadena de conexión tenga authSource=admin: el usuario está creado en la base admin, mientras que los permisos se otorgan en ${MONGO_DB}" ;;
    *)
      fail "no se pudo ejecutar la consulta contra la base ${MONGO_DB}${ERR:+: $ERR}" \
           "comprueba manualmente: kubectl exec -it mongo-workbench -- sh -c 'mongosh \"\$MONGO_URI\"'" ;;
  esac
  finish
  exit $?
fi

ok "la conexión a la base ${MONGO_DB} con el usuario ${MONGO_USER} funciona"

# --- 2. hay documentos ------------------------------------------------------
TOTAL="$(num total)"
if [ "$TOTAL" -ge 4 ]; then
  ok "documentos en la colección ${MONGO_COLL}: ${TOTAL}"
else
  fail "la colección ${MONGO_COLL} tiene solo ${TOTAL} documentos, se esperaban al menos cuatro" \
       "carga los pases: mo < passes.js (el análisis del archivo está en el README)"
fi

# --- 3. las formas realmente son distintas ---------------------------------
TYPES="$(num types)"
if [ "$TYPES" -ge 4 ]; then
  ok "en la colección hay ${TYPES} tipos de pase distintos"
else
  fail "solo ${TYPES} tipos de pase distintos, se esperaban cuatro" \
       "comprueba que passes.js se cargó por completo: db.passes.distinct('type')"
fi

WITH_CAR="$(num withCar)"
if [ "$WITH_CAR" -ge 1 ]; then
  ok "hay documentos con un objeto anidado (car.plate): ${WITH_CAR}"
else
  fail "no hay ni un solo documento con un objeto anidado car" \
       "el pase de vehículo no se cargó; repite mo < passes.js"
fi

WITH_ARRAY="$(num withArray)"
if [ "$WITH_ARRAY" -ge 2 ]; then
  ok "hay documentos con listas (entrances y members): ${WITH_ARRAY}"
else
  fail "documentos con listas: ${WITH_ARRAY}, se esperaban al menos dos" \
       "el pase semanal y el de grupo no se cargaron; repite mo < passes.js"
fi

NESTED="$(num nested)"
if [ "$NESTED" -ge 1 ]; then
  ok "la búsqueda dentro de una lista de objetos (members.name) encuentra documentos"
else
  fail "la búsqueda por members.name no encontró nada" \
       "el pase de grupo con la lista de participantes no se cargó; repite mo < passes.js"
fi

evidence "Composición de la colección" "documentos: ${TOTAL}
tipos de pase distintos: ${TYPES}
con objeto anidado car: ${WITH_CAR}
con listas: ${WITH_ARRAY}"

# --- 4. índice sobre un campo raro -----------------------------------------
SPARSE="$(mget sparse)"
IDX="$(mget indexes)"
if [ -n "$SPARSE" ]; then
  ok "hay un índice disperso (o parcial) construido: ${SPARSE}"
  evidence "Índices de la colección" "todos: ${IDX}
dispersos: ${SPARSE}"
else
  fail "no hay índice disperso — la búsqueda por número de coche va por recorrido completo" \
       "créalo: db.${MONGO_COLL}.createIndex({ 'car.plate': 1 }, { name: 'car_plate', sparse: true })"
  evidence "Índices de la colección" "todos: ${IDX}"
fi

# --- 5. el validador de esquema está activado ------------------------------
VALIDATOR="$(num validator)"
ACTION="$(mget validationAction)"
if [ "$VALIDATOR" = "1" ]; then
  ok "el validador de esquema está activado (acción en caso de infracción: ${ACTION:-por defecto})"
  if [ "$ACTION" = "warn" ]; then
    warn "el validador solo advierte, pero acepta los documentos" \
         "para una colección de producción hace falta validationAction: error"
  fi
else
  fail "el validador de esquema no está activado — un error tipográfico en el nombre de un campo pasaría en silencio" \
       "actívalo: mo < validator.js (ver el análisis del fallo predecible en el README)"
fi

# --- 6. documentos corruptos eliminados ------------------------------------
TYPELESS="$(num typeless)"
if [ "$TYPELESS" -eq 0 ]; then
  ok "no quedan documentos sin el campo type"
else
  fail "en la colección hay ${TYPELESS} documentos sin el campo type — la seguridad no los verá" \
       "encuéntralos y elimínalos: db.${MONGO_COLL}.deleteMany({ type: { \$exists: false } })"
fi

# finish imprime el resultado y guarda el informe-artefacto en un archivo; el código de retorno es distinto de cero
# si al menos una comprobación falló.
finish
