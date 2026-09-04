#!/usr/bin/env bash
# Comprobación del lab 5: el estado del clúster proviene de Git y se mantiene mediante la reconciliación.
#
# Se ejecuta contra tu clúster `lab`, desde la carpeta del lab, por ti mismo:
#     export KUBECONFIG=~/lab.kubeconfig
#     ./check.sh
# No cambia nada — solo observa e imprime un informe: qué se comprobó, qué pasó,
# qué no, y las evidencias adjuntas.
#
# No comprobamos "Flux está instalado" sino "el mecanismo funciona": la fuente se lee, lo que
# se aplica pertenece a Flux, el servicio responde, la reconciliación no está desactivada. Un Flux
# instalado pero suspendido es la forma más común de aprobar el lab y perder su sentido.

LAB_NAME="05-gitops"
LAB_TITLE="Lab 5 · Infraestructura en Git"
# Andamiaje compartido de todos los labs: proporciona ok / fail / warn / evidence / finish y las
# comprobaciones del entorno. La ruta se calcula respecto a la ubicación de este archivo, por lo que el script
# se puede ejecutar desde cualquier carpeta.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Sin un archivo de acceso al clúster no hay nada que comprobar — salimos de inmediato con una razón clara.
need_kubeconfig

# Los nombres que crea este lab. Reunidos en un solo lugar: si un participante nombró los objetos
# de otra forma, edítalos aquí en vez de buscar nombres por todo el script.
NS_APP="passes"
GITREPO="passes"
KUSTOMIZATION="passes"

# Lee un campo de un objeto sin fallar si el objeto o la CRD no existe.
kget() { kubectl get "$@" 2>/dev/null; }

# --- servicios de Flux -----------------------------------------------------
# No miramos "los pods existen" sino "al menos una réplica está Ready": un pod puede quedarse en
# Pending sin memoria en el nodo y aun así aparecer en la salida de get pods.
# Ambos servicios son obligatorios y reparten el trabajo: source-controller descarga el repositorio,
# kustomize-controller aplica lo descargado. Sin el segundo, nada llega al clúster.
if ! kget namespace flux-system >/dev/null; then
  fail "el clúster no tiene el espacio de nombres flux-system" \
       "Flux no está instalado: flux install --components=source-controller,kustomize-controller"
else
  FLUX_BAD=""
  for d in source-controller kustomize-controller; do
    READY="$(kget deployment "$d" -n flux-system -o jsonpath='{.status.readyReplicas}')"
    [ "${READY:-0}" -ge 1 ] 2>/dev/null || FLUX_BAD="$FLUX_BAD $d"
  done
  if [ -z "$FLUX_BAD" ]; then
    ok "los servicios de Flux funcionan: source-controller y kustomize-controller"
    evidence "Pods de Flux" "$(kget pods -n flux-system -o wide)"
  else
    fail "los servicios de Flux no funcionan:${FLUX_BAD}" \
         "revisa kubectl get pods -n flux-system; en un nodo pequeño puede faltarles memoria"
  fi
fi

# --- fuente: GitRepository --------------------------------------------------
# Tres resultados distintos, y no se deben confundir: el objeto no existe en absoluto;
# el objeto existe pero aún conserva una dirección de marcador de posición; el objeto existe con una dirección real
# pero Flux no pudo leer el repositorio. El consejo difiere en cada caso, por eso las ramas difieren.
#
# Tomamos la señal de éxito de status.conditions — eso es lo que Flux informa sobre sí mismo
# después de intentar llegar a Git, no nuestra suposición basada en la presencia del objeto.
if ! kubectl api-resources --api-group=source.toolkit.fluxcd.io 2>/dev/null | grep -q gitrepositories; then
  fail "el clúster no tiene el tipo GitRepository" \
       "Flux no está instalado, o instalado sin source-controller"
else
  GR_URL="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.spec.url}')"
  GR_READY="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  GR_MSG="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  GR_REV="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.status.artifact.revision}')"

  if [ -z "$GR_URL" ]; then
    fail "no se encontró un GitRepository con el nombre ${GITREPO} en flux-system" \
         "aplica flux/gitrepository.yaml con la dirección de tu repositorio rellenada"
  elif printf '%s' "$GR_URL" | grep -q 'ЗАМЕНИТЕ-МЕНЯ'; then
    fail "el GitRepository aún tiene una dirección de marcador de posición" \
         "abre flux/gitrepository.yaml e introduce la dirección de tu propio repositorio de GitHub"
  elif [ "$GR_READY" = "True" ]; then
    ok "Flux lee tu repositorio: ${GR_URL}"
    evidence "Fuente en Git" "url: ${GR_URL}
revision: ${GR_REV:-desconocida}"
  else
    fail "Flux no puede leer el repositorio ${GR_URL}" \
         "revisa flux get sources git; lo más frecuente es un error tipográfico en la dirección, un repositorio privado, u otra rama"
    evidence "Error de fuente" "${GR_MSG:-sin mensaje}"
  fi
fi

# --- aplicación: Kustomization ----------------------------------------------
# Aquí no comprobamos el hecho de aplicar, sino tres propiedades del mecanismo sin las cuales
# el lab pierde su sentido: la revisión aplicada coincide con Git, la reconciliación no está suspendida, y
# está activada la eliminación de lo que desapareció del repositorio.
KS_READY=""
if ! kubectl api-resources --api-group=kustomize.toolkit.fluxcd.io 2>/dev/null | grep -q kustomizations; then
  fail "el clúster no tiene el tipo Kustomization" \
       "Flux se instaló sin kustomize-controller — reinstala con ambos componentes"
else
  KS_READY="$(kget kustomization "$KUSTOMIZATION" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  KS_MSG="$(kget kustomization "$KUSTOMIZATION" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  KS_REV="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.status.lastAppliedRevision}')"
  KS_SUSPEND="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.suspend}')"
  KS_PRUNE="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.prune}')"
  KS_INTERVAL="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.interval}')"

  if [ -z "$KS_REV" ] && [ -z "$KS_READY" ]; then
    fail "no se encontró un Kustomization con el nombre ${KUSTOMIZATION} en flux-system" \
         "aplica flux/kustomization.yaml"
  elif [ "$KS_READY" = "True" ]; then
    ok "Flux aplicó el estado desde Git, revisión ${KS_REV}"
    evidence "Revisión aplicada" "$KS_REV"
  else
    fail "Flux no pudo aplicar el estado desde Git" \
         "revisa flux get kustomizations y kubectl describe kustomization ${KUSTOMIZATION} -n flux-system"
    evidence "Error de aplicación" "${KS_MSG:-sin mensaje}"
  fi

  # Un Flux suspendido parece instalado y no hace nada. Esta es la forma principal de "aprobar" el
  # lab sin obtener ni uno solo de sus beneficios.
  if [ "$KS_SUSPEND" = "true" ]; then
    fail "la reconciliación está suspendida (suspend: true) — Flux no está vigilando el clúster" \
         "vuelve a activarla: flux resume kustomization ${KUSTOMIZATION}"
  else
    ok "la reconciliación está activa: la desviación respecto a Git se corregirá sola, intervalo ${KS_INTERVAL:-predeterminado}"
  fi

  # Esto es un warn, no un fail: sin prune el clúster sigue gestionándose desde Git, el lab está aprobado.
  # Pero la descripción se vuelve unilateral — eliminar un archivo no elimina nada en el clúster.
  if [ "$KS_PRUNE" = "true" ]; then
    ok "está activada la eliminación de lo que desapareció de Git (prune)"
  else
    warn "prune está desactivado — lo eliminado del repositorio seguirá funcionando en el clúster" \
         "pon prune: true en flux/kustomization.yaml, de lo contrario Git describe solo la mitad del estado"
  fi
fi

# --- los objetos en el clúster pertenecen a Flux, no aplicados a mano ---------
# Esta es la comprobación clave del lab, y trata sobre la procedencia, no sobre la presencia. La aplicación
# está en el clúster en ambos casos: cuando la trajo Flux, y cuando el participante aplicó los
# mismos archivos a mano con kubectl apply. Externamente indistinguibles — el Deployment es idéntico.
# La etiqueta de propietario los distingue: solo kustomize-controller la pone cuando aplica el
# contenido del repositorio. Un objeto aplicado a mano no obtendrá esa etiqueta.
OWNER="$(kget deployment passes -n "$NS_APP" \
  -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}')"
if [ -z "$(kget deployment passes -n "$NS_APP" -o name)" ]; then
  fail "no hay aplicación passes en el espacio de nombres ${NS_APP}" \
       "coloca app/*.yaml en la carpeta apps de tu repositorio, haz push y espera la reconciliación"
elif [ "$OWNER" = "$KUSTOMIZATION" ]; then
  ok "la aplicación en el clúster pertenece a Flux, no aplicada a mano"
else
  fail "la aplicación passes existe, pero no la creó Flux" \
       "elimínala (kubectl delete ns ${NS_APP}) y deja que Flux la despliegue desde Git de nuevo"
fi

# --- la aplicación realmente responde --------------------------------------
# Un objeto en el clúster y un servicio en funcionamiento son cosas distintas: un Deployment puede crearse
# mientras los pods se caen en bucle. Por eso entramos al clúster y solicitamos el servicio por su nombre
# interno — la misma vía que usarían las aplicaciones vecinas para alcanzarlo.
PODS="$(kget pods -n "$NS_APP" -l app=passes --no-headers)"
PODS_READY="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BODY="$(in_cluster_curl "http://passes.${NS_APP}.svc.cluster.local/")"

if printf '%s' "$BODY" | grep -q 'Пропуск'; then
  ok "el servicio «Пропуск» responde por HTTP dentro del clúster (réplicas en funcionamiento: ${PODS_READY})"
else
  fail "el servicio «Пропуск» no responde en passes.${NS_APP}.svc.cluster.local" \
       "revisa kubectl get pods -n ${NS_APP} y kubectl logs -n ${NS_APP} deploy/passes"
fi

# El nombre del pod en la página debe coincidir con una réplica realmente en ejecución: esto muestra que
# la respuesta proviene exactamente del pod que vemos en el clúster, y no de una respuesta en caché o de otro
# servicio que casualmente tomó el mismo nombre. Una discrepancia es un warn, no un fail: la réplica pudo
# haberse recreado entre dos solicitudes, y eso no es un error del participante.
SERVED_POD="$(printf '%s' "$BODY" | grep -o 'passes-[a-z0-9]*-[a-z0-9]*' | head -1)"
if [ -n "$SERVED_POD" ] && printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
  ok "la página la sirvió un pod realmente existente ${SERVED_POD}"
  evidence "Réplicas del servicio" "$(kget pods -n "$NS_APP" -o wide)"
elif [ -n "$SERVED_POD" ]; then
  warn "el pod ${SERVED_POD} de la respuesta no se encontró entre los que están en ejecución" \
       "lo más probable es que la réplica se recreó entre dos solicitudes — ejecuta la comprobación de nuevo"
fi

# --- historial de cambios en tu clon del repositorio ----------------------------
# Parte opcional: el script no sabe dónde está el clon hasta que se le indica.
# Lo que se comprueba aquí es el método de reversión. Con kubectl rollout undo el clúster también vuelve
# a la versión anterior, pero Git no se entera, y la siguiente reconciliación trae el cambio malo
# de vuelta. Por eso buscamos un revert en el historial — la reversión se hace donde vive la
# verdad. Y verificamos que la revisión aplicada en el clúster coincide con tu HEAD:
# hacer commit y olvidar el push es algo común, y desde fuera parece que "Flux está atascado".
REPO="${LAB_REPO:-}"
if [ -z "$REPO" ]; then
  warn "no se comprobó el historial del repositorio: la variable LAB_REPO no está definida" \
       "para comprobarlo también: export LAB_REPO=~/passes-gitops && ./check.sh"
elif [ ! -d "$REPO/.git" ]; then
  warn "no hay clon del repositorio en ${REPO}" \
       "indica la carpeta en la que ejecutaste git clone"
else
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null | cut -c1-7)"
  LOG="$(git -C "$REPO" log --oneline -20 2>/dev/null)"

  if printf '%s' "$LOG" | grep -qi '^[0-9a-f]* *revert'; then
    ok "el historial tiene una reversión mediante git revert — el cambio malo se deshizo donde vive la verdad"
    evidence "Historial de cambios" "$LOG"
  else
    fail "no hay ningún revert en los últimos commits" \
         "revierte el cambio malo con git revert --no-edit HEAD y haz push, no con kubectl rollout undo"
  fi

  # Lo aplicado en el clúster debe coincidir con el último commit de la rama.
  if [ -n "$HEAD_SHA" ] && printf '%s' "${KS_REV:-}" | grep -q "$HEAD_SHA"; then
    ok "el clúster ejecuta exactamente lo que está en tu rama (commit ${HEAD_SHA})"
  elif [ -n "$HEAD_SHA" ]; then
    warn "el commit en el clúster (${KS_REV:-desconocido}) difiere del HEAD local (${HEAD_SHA})" \
         "comprueba que los commits locales se hayan enviado (git push), y espera el intervalo de reconciliación"
  fi
fi

finish
