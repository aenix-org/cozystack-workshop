#!/usr/bin/env bash
# Comprobación del lab 13: el chart y la definición de la aplicación están listos para entregar al admin.
#
# Esta comprobación es INTENCIONADAMENTE local. Un tenant no puede aplicar un ApplicationDefinition
# (el objeto es cluster-scoped), por lo que buscarlo en el clúster no tiene sentido:
# la ausencia del objeto no es culpa del participante. Comprobamos aquello de lo que es responsable:
# el chart se construye, el esquema funciona, la definición se analiza y es coherente con el chart.
#
# Ejecutar desde la carpeta del lab:
#   cd labs/13-catalog && ./check.sh
# No se requiere un clúster: sin KUBECONFIG dos comprobaciones se omiten con una advertencia,
# no con un error.

LAB_NAME="13-catalog"
LAB_TITLE="Lab 13 · Tu propia aplicación en el catálogo de Cozystack"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$HERE/chart"
APPDEF="$HERE/applicationdefinition.yaml"

# --- herramientas ----------------------------------------------------------
# Sin helm no hay nada que comprobar, así que el script se detiene aquí mismo en lugar de soltar
# una docena de fallos idénticos más abajo en el texto.
if ! command -v helm >/dev/null 2>&1; then
  fail "helm no está instalado en esta máquina" \
       "instálalo: brew install helm (macOS) o https://helm.sh/docs/intro/install/ — sin él el lab no se puede comprobar"
  finish
  exit $?
fi
HELM_VER="$(helm version --short 2>/dev/null)"
ok "helm está presente (${HELM_VER})"
evidence "versión de helm" "$HELM_VER"

# --- chart en su sitio -----------------------------------------------------
# Distinguimos «el chart está roto» de «el script se ejecutó desde la carpeta equivocada». El segundo
# error es más común que el primero, y su mensaje debe ser separado.
if [ ! -f "$CHART/Chart.yaml" ]; then
  fail "chart no encontrado en ${CHART}" \
       "ejecuta el script desde la carpeta del lab: cd labs/13-catalog && ./check.sh"
  finish
  exit $?
fi

# --- linter ----------------------------------------------------------------
# helm lint lee el chart como texto: encuentra erratas en las plantillas, campos faltantes
# de Chart.yaml, referencias a valores inexistentes. Aquí nunca llega al clúster.
LINT_OUT="$(helm lint "$CHART" 2>&1)"
if printf '%s' "$LINT_OUT" | grep -q '0 chart(s) failed'; then
  ok "el chart pasa helm lint"
  evidence "helm lint" "$LINT_OUT"
else
  fail "el chart no pasa helm lint" \
       "lee la salida de abajo y arregla los archivos indicados: helm lint chart"
  evidence "helm lint" "$LINT_OUT"
fi

# --- render ----------------------------------------------------------------
# La salida vacía y la salida compuesta solo de comentarios se colarían por el linter, así que comprobamos
# que entre lo renderizado hay un Deployment, y listamos lo que realmente se produjo.
# Lo importante aquí no es «el comando se ejecutó» sino «salieron objetos reales».
RENDER="$(helm template main "$CHART" 2>&1)"
if printf '%s' "$RENDER" | grep -q '^kind: Deployment'; then
  KINDS="$(printf '%s' "$RENDER" | grep '^kind:' | awk '{print $2}' | sort -u | tr '\n' ' ')"
  ok "el chart renderiza, produciendo objetos: ${KINDS}"
  evidence "Qué renderiza el chart" "$KINDS"
else
  fail "helm template no produjo ni un solo Deployment" \
       "mira el error de render: helm template main chart"
  evidence "salida de helm template" "$(printf '%s' "$RENDER" | head -30)"
fi

# --- el chart es aceptado por un clúster real ------------------------------
# La única comprobación de todo el conjunto de labs que verifica el manifiesto contra el esquema de un clúster real
# en lugar de contra texto.
#
# `helm lint` y `helm template` comprueban plantillas, pero NO el esquema de Kubernetes: un manifiesto
# con un campo en el lugar equivocado se les cuela, pero el clúster lo rechaza. Aprendido a las duras —
# un securityContext insertado por error en volumes pasó ambos y se desmoronó solo
# en el servidor. La comprobación es necesaria allí donde el chart se aplica realmente.
#
# Por qué lint y template no la reemplazan:
#   helm lint      mira la estructura del chart: archivos en su sitio, las plantillas se analizan;
#   helm template  sustituye valores y produce texto — pero qué son esos campos y si
#                  tal objeto siquiera los tiene, no lo sabe ni puede saberlo;
#   apply --dry-run=server envía el manifiesto al apiserver, que lo pasa por el esquema del tipo
#                  y por el control de admisión y responde si lo aceptaría, sin crear
#                  nada en el proceso. De ahí vienen `unknown field` y un rechazo por política —
#                  exactamente con lo que el chart tropieza en casa del cliente.
# El flag --dry-run=client no da esta comprobación: analiza el manifiesto en tu máquina.
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  DRY="$(printf '%s' "$RENDER" | kubectl apply --dry-run=server -f - 2>&1)"
  # Una denegación de permisos y una denegación de esquema son cosas distintas, y no deben confundirse. Bajo
  # el acceso de tenant (~/.kube/config) no hay derechos sobre Deployment ni ConfigMap en absoluto, así que
  # lo que llega aquí es Forbidden — y eso no dice nada sobre la calidad del chart. Una comprobación sustantiva
  # solo es posible con acceso al clúster `lab`, donde eres el dueño pleno.
  if printf '%s' "$DRY" | grep -qiE 'forbidden|cannot create|is not allowed'; then
    warn "comprobación del chart en el servidor omitida: el acceso actual no permite ejecutarla" \
         "ejecútala con acceso a tu propio clúster: KUBECONFIG=~/lab.kubeconfig ./check.sh"
  elif printf '%s' "$DRY" | grep -qiE 'error|unknown field|invalid'; then
    fail "el clúster rechaza el chart renderizado" \
         "mira: helm template main chart | kubectl apply --dry-run=server -f -"
    evidence "Rechazo del servidor" "$(printf '%s' "$DRY" | grep -iE 'error|unknown field' | head -5)"
  else
    ok "el clúster acepta el chart renderizado — los campos y sus lugares son correctos"
  fi
else
  warn "comprobación del chart en el clúster omitida: sin acceso" \
       "define KUBECONFIG para ejecutar helm template a través de kubectl apply --dry-run=server"
fi

# --- los parámetros realmente llegan a los manifiestos ---------------------
# Un chart puede construirse y renderizarse, y sin embargo un parámetro no sustituirse en ninguna parte —
# por ejemplo, el valor se escribió en la plantilla como un número literal. Por eso comprobamos cada
# parámetro de verdad: fijamos un valor deliberadamente inusual y lo buscamos en el manifiesto terminado.
R5="$(helm template main "$CHART" --set replicas=5 2>/dev/null | grep -c 'replicas: 5')"
if [ "${R5:-0}" -ge 1 ]; then
  ok "el parámetro replicas llega al manifiesto (--set replicas=5 da replicas: 5)"
else
  fail "el parámetro replicas no llega al manifiesto" \
       "templates/deployment.yaml debería tener replicas: {{ .Values.replicas }}"
fi

EXT="$(helm template main "$CHART" --set external=true 2>/dev/null | grep -c 'type: LoadBalancer')"
if [ "${EXT:-0}" -ge 1 ]; then
  ok "el parámetro external cambia el tipo de Service a LoadBalancer"
else
  warn "el parámetro external no cambia el tipo de Service" \
       "no es una rotura del chart, sino una convención del catálogo de Cozystack: el campo external en las aplicaciones significa exactamente acceso externo"
fi

# --- el esquema realmente protege ------------------------------------------
# Un esquema que no rechaza nada es inútil. Comprobamos que rechaza.
if helm template main "$CHART" --set replicas=abc >/dev/null 2>&1; then
  fail "el esquema de valores no rechaza un valor deliberadamente inválido (replicas=abc pasó)" \
       "comprueba que values.schema.json esté junto a values.yaml y declare replicas como integer"
else
  ok "el esquema de valores rechaza el tipo incorrecto (replicas=abc no pasa)"
fi

# --- ApplicationDefinition: campos obligatorios ----------------------------
# El participante no puede aplicar la definición, así que no verá el rechazo del apiserver.
# Por eso contamos aquí los campos obligatorios: sin alguno de ellos el admin recibe un rechazo
# en su propio lado, y el autor del archivo es quien tendrá que resolverlo.
if [ ! -f "$APPDEF" ]; then
  fail "${APPDEF} no encontrado" \
       "el archivo debería estar junto al chart; tómalo del repositorio de labs"
else
  MISSING=""
  # Buscamos claves línea por línea, sin analizar YAML: PyYAML no está en todas las máquinas,
  # y arrastrar una dependencia solo para comprobar un archivo no vale la pena.
  check_key() {
    grep -Eq "$1" "$APPDEF" || MISSING="$MISSING $2"
  }
  check_key '^kind:[[:space:]]+ApplicationDefinition[[:space:]]*$' 'kind: ApplicationDefinition'
  check_key '^apiVersion:[[:space:]]+cozystack\.io/v1alpha1[[:space:]]*$' 'apiVersion: cozystack.io/v1alpha1'
  check_key '^[[:space:]]{4}kind:[[:space:]]+\S+' 'application.kind'
  check_key '^[[:space:]]{4}plural:[[:space:]]+\S+' 'application.plural'
  check_key '^[[:space:]]{4}singular:[[:space:]]+\S+' 'application.singular'
  check_key '^[[:space:]]{4}openAPISchema:' 'application.openAPISchema'
  check_key '^[[:space:]]{4}prefix:[[:space:]]+\S+' 'release.prefix'
  check_key '^[[:space:]]{6}kind:[[:space:]]+(OCIRepository|HelmChart|ExternalArtifact)' 'release.chartRef.kind'
  check_key '^[[:space:]]{4}category:[[:space:]]+\S+' 'dashboard.category'
  check_key '^[[:space:]]{4}icon:[[:space:]]+\S+' 'dashboard.icon'

  if [ -z "$MISSING" ]; then
    ok "todos los campos obligatorios están presentes en el ApplicationDefinition"
  else
    fail "al ApplicationDefinition le faltan campos:${MISSING}" \
         "compáralo con el recorrido del README — sin alguno de ellos el admin recibe un rechazo al aplicar"
  fi

  # --- el esquema en la definición se analiza y coincide con el esquema del chart ---
  # Son dos copias separadas de lo mismo, sin ningún vínculo entre ellas.
  # Si divergen, el formulario en el dashboard mostrará campos distintos de los que el chart espera.
  SCHEMA_LINE="$(awk '/openAPISchema:/{getline; sub(/^[[:space:]]+/,""); print; exit}' "$APPDEF")"
  if [ -z "$SCHEMA_LINE" ]; then
    fail "openAPISchema está vacío en el ApplicationDefinition" \
         "pega el contenido de chart/values.schema.json ahí como una sola línea"
  else
    CMP="$(SCHEMA_LINE="$SCHEMA_LINE" python3 - "$CHART/values.schema.json" <<'PY' 2>&1
import os, sys, json
try:
    inline = json.loads(os.environ["SCHEMA_LINE"])
except Exception as e:
    print("BADJSON %s" % e); raise SystemExit
try:
    chart = json.load(open(sys.argv[1]))
except Exception as e:
    print("NOCHART %s" % e); raise SystemExit
a = sorted((inline.get("properties") or {}).keys())
b = sorted((chart.get("properties") or {}).keys())
if a == b:
    print("SAME %s" % ",".join(a))
else:
    only_def = sorted(set(a) - set(b))
    only_chart = sorted(set(b) - set(a))
    print("DIFF solo en la definición: %s | solo en el chart: %s"
          % (",".join(only_def) or "-", ",".join(only_chart) or "-"))
PY
)"
    case "$CMP" in
      SAME*)
        ok "el esquema en la definición se analiza y coincide con el esquema del chart (${CMP#SAME })"
        evidence "Parámetros de la aplicación" "${CMP#SAME }"
        ;;
      DIFF*)
        fail "el esquema en la definición ha divergido del esquema del chart: ${CMP#DIFF }" \
             "ponlos de acuerdo: el contenido de openAPISchema es chart/values.schema.json como una sola línea"
        ;;
      BADJSON*)
        fail "openAPISchema no se analiza como JSON: ${CMP#BADJSON }" \
             "el esquema debe ser una sola línea de JSON válido bajo 'openAPISchema: |-'"
        ;;
      *)
        warn "no se pudieron comparar los esquemas (${CMP})" \
             "comprueba a mano que openAPISchema coincide con chart/values.schema.json"
        ;;
    esac
  fi

  # --- icono ----------------------------------------------------------------
  # El dashboard espera un SVG empaquetado en base64 y no va a ningún sitio a por la imagen. El error
  # aquí es silencioso: el manifiesto se aplica, pero en el catálogo el lugar del icono estará vacío. Por eso
  # decodificamos la cadena y comprobamos que dentro haya realmente un SVG.
  ICON="$(grep -Eo '^[[:space:]]{4}icon:[[:space:]]+\S+' "$APPDEF" | head -1 | awk '{print $2}')"
  if [ -n "$ICON" ]; then
    ICON_HEAD="$(printf '%s' "$ICON" | python3 -c 'import sys,base64
try:
    print(base64.b64decode(sys.stdin.read().strip()).decode("utf-8","replace")[:40])
except Exception:
    print("")' 2>/dev/null)"
    case "$ICON_HEAD" in
      *"<svg"*)
        ok "el icono se decodifica de base64 y resulta ser un SVG"
        evidence "Inicio del icono" "$ICON_HEAD"
        ;;
      "")
        fail "el icono no se decodifica de base64" \
             "reconstruye la cadena: base64 -i icon.svg | tr -d '\\n' (en Linux: base64 -w0 icon.svg)"
        ;;
      *)
        fail "el icono se decodifica, pero no es un SVG" \
             "el dashboard espera exactamente un SVG; una imagen ráster la mostrará como basura"
        ;;
    esac
  fi
fi

# --- permisos: aquí se espera una denegación -------------------------------
# Esto no es una comprobación del participante, sino una confirmación de cómo está construida la plataforma. Así que
# la respuesta `no` es un éxito, y `yes` es un motivo para sorprenderse, no para alegrarse.
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  CANI="$(kubectl auth can-i create applicationdefinitions 2>/dev/null)"
  case "$CANI" in
    no)
      ok "confirmado: no tienes permitido aplicar un ApplicationDefinition (can-i -> no)"
      evidence "Derechos sobre ApplicationDefinition" \
        "kubectl auth can-i create applicationdefinitions -> no
El objeto es cluster-scoped y cambia el catálogo para todos los tenants, por eso es el admin de la plataforma quien lo aplica."
      ;;
    yes)
      warn "tienes derechos para aplicar un ApplicationDefinition (can-i -> yes)" \
           "eso significa que trabajas bajo una cuenta de admin, no de tenant; el lab está diseñado para una cuenta de tenant"
      ;;
    *)
      warn "no se pudo preguntar al clúster sobre los permisos" \
           "no afecta a la aprobación del lab: la comprobación es local, el clúster no es necesario aquí"
      ;;
  esac
else
  warn "no se consultó al clúster (KUBECONFIG no está definido o no responde)" \
       "la comprobación es local, el clúster no es necesario aquí. Para ver la denegación de permisos: export KUBECONFIG=~/.kube/config"
fi

finish
