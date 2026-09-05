#!/usr/bin/env bash
# Verificación del lab 12: la máquina virtual migrada se publica hacia el exterior a través del
# ingress y el dominio de la plataforma, exactamente igual que la aplicación en contenedor.
#
# No comprobamos «los objetos están creados», sino que la cosa funciona de verdad:
#   1) el nombre de dominio del tenant devuelve HTTP 200 y es la página del directorio,
#   2) la propia máquina virtual está en ejecución (Ready),
#   3) el Ingress que publica la máquina está en su sitio.
# El primer punto es el principal: es la prueba de que el directorio se ve desde fuera.
#
# Se ejecuta en el portátil, desde la carpeta de este lab. Necesita acceso al tenant y el número del tenant:
#     export KUBECONFIG=~/.kube/workshop
#     export COZY_TENANT=workshopXX
#     cd labs/12-vm && ./check.sh
# La comprobación por dominio funciona incluso sin acceso al tenant: le basta con curl. Sin acceso
# al tenant el script no falla: se salta las comprobaciones del lado del tenant y lo indica.
#
# El script no cambia nada: solo lee y envía peticiones HTTP. Ejecútalo antes de la limpieza:
# una vez eliminada la máquina no quedará nada que comprobar.

# lib.sh recoge estas dos variables: van a la cabecera del informe y al nombre del
# archivo report-<lab>-<fecha>.md, que el script deja junto a sí mismo.
LAB_NAME="12-vm"
LAB_TITLE="Lab 12 · Una máquina virtual junto a los contenedores"
# Biblioteca común de comprobaciones: de aquí vienen ok / fail / warn / evidence / finish.
# La ruta se calcula respecto al lugar donde está el propio script, así que ejecutar desde
# cualquier directorio funciona igual.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# El número del tenant es obligatorio: de él se forman tanto el nombre del namespace como el nombre
# de dominio en el que se publica el directorio. Sin él no hay nada que comprobar.
need_tenant

# Los nombres que comprobamos. VM es el nombre del PEDIDO de máquina, es decir, del objeto VMInstance;
# es lo que se pregunta con `kubectl get vminstance`. La instancia realmente en ejecución se llama
# de otra forma: la plataforma despliega el pedido con el chart `vm-instance`, el nombre del chart se
# pega al nombre del release, y sale vm-instance-spravochnik.
VM=spravochnik
NS="tenant-${COZY_TENANT}"
# El dominio en el que el ponente publicó de antemano el directorio a través de Ingress. La misma
# dirección que abres en el navegador.
HOST="spravochnik.${COZY_TENANT}.workshop.aenix.io"
URL="http://${HOST}"

# El acceso al tenant no es obligatorio: el dominio se comprueba con un curl normal. Si KUBECONFIG
# está definido y el tenant responde, añadimos comprobaciones del estado de la máquina y del Ingress.
TENANT_OK=0
if [ -n "${KUBECONFIG:-}" ] && kubectl -n "$NS" get vminstance >/dev/null 2>&1; then
  TENANT_OK=1
fi

# --- lo principal: el directorio se ve desde fuera por el dominio ---------------------------
# Tomamos por separado el código de respuesta y el cuerpo: el código distingue «todavía no hay nadie
# tras el ingress» (503) de «lleva al sitio equivocado» (404) y «no hay dominio en absoluto» (000),
# y el cuerpo confirma que quien responde es exactamente el directorio, y no un stub cualquiera.
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL" 2>/dev/null)"
BODY="$(curl -s --max-time 10 "$URL" 2>/dev/null)"

case "$CODE" in
  200)
    case "$BODY" in
      *"Directorio de personal"*)
        ok "directorio publicado: ${URL} responde 200 y sirve la página del directorio"
        evidence "Respuesta por el dominio" "petición: ${URL}
código de respuesta: ${CODE}
$(printf '%s' "$BODY" | head -3)"
        ;;
      *)
        fail "${URL} devuelve 200, pero no es la página del directorio" \
             "detrás del dominio responde otra cosa; comprueba que en el puerto 8080 dentro de la máquina escucha exactamente el directorio"
        ;;
    esac
    ;;
  503)
    fail "el dominio ${URL} responde 503 — todavía no hay nadie tras el Ingress para responder" \
         "la máquina aún está arrancando o el servicio del directorio en el 8080 no ha levantado; espera a que la vminstance esté Ready y mira la consola de la máquina"
    ;;
  000)
    fail "el dominio ${URL} no responde en absoluto" \
         "comprueba la red; el Ingress con este host lo crea el ponente — si no hay dominio en absoluto, pregúntale a él"
    ;;
  *)
    fail "el dominio ${URL} responde ${CODE}, no 200" \
         "404 significa que el Ingress lleva al servicio equivocado; 5xx que el backend no está listo para responder"
    ;;
esac

# --- lado del tenant: la propia máquina y su publicación --------------------------
if [ "$TENANT_OK" -eq 0 ]; then
  warn "comprobaciones del lado del tenant omitidas: el tenant no es accesible por KUBECONFIG" \
       "proporciona acceso al tenant: export KUBECONFIG=~/.kube/workshop"
else
  # No preguntamos «existe el objeto», sino la condición Ready: el pedido de máquina se crea en
  # un segundo, mientras que el huésped tarda de tres a cinco minutos en levantar, y todo ese tiempo
  # la máquina existe pero el directorio todavía no responde.
  if ! kubectl -n "$NS" get vminstance "$VM" >/dev/null 2>&1; then
    fail "en el tenant ${NS} no hay ninguna máquina virtual ${VM}" \
         "crea un VM Disk y un VM Instance en el panel o aplica staff-directory-vm.yaml"
  else
    VM_READY="$(kubectl -n "$NS" get vminstance "$VM" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    if [ "$VM_READY" = "True" ]; then
      ok "la máquina virtual ${VM} está en ejecución"
    elif [ -n "$VM_READY" ]; then
      fail "la máquina virtual ${VM} existe, pero no está lista (Ready=${VM_READY})" \
           "mira la ficha de la máquina en el panel; el primer arranque tarda de 3 a 5 minutos"
    else
      warn "la máquina virtual ${VM} existe, pero no se pudo leer su estado" \
           "míralo con tus propios ojos en el panel: debería estar encendida"
    fi
    evidence "Máquinas virtuales del tenant" "$(kubectl -n "$NS" get vminstance 2>/dev/null)"
  fi

  # El Ingress lo crea el ponente, no el participante. Si el dominio ya responde 200 — está en su
  # sitio; lo comprobamos por separado para que ante un 503/404 se vea enseguida si existe alguna
  # publicación en absoluto.
  if kubectl -n "$NS" get ingress spravochnik >/dev/null 2>&1; then
    ok "el Ingress spravochnik está en su sitio — el directorio está publicado en el tenant"
    evidence "Ingress del tenant" "$(kubectl -n "$NS" get ingress spravochnik 2>/dev/null)"
  else
    warn "no se encontró el Ingress spravochnik en el tenant ${NS}" \
         "lo crea el ponente; si el dominio ya responde 200 — no hay de qué preocuparse, en caso contrario dirígete al ponente"
  fi
fi

finish
