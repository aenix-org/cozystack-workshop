# Lab 12 · Una VM junto a los contenedores

| | |
|---|---|
| **Tiempo** | 30 minutos, de los cuales 5–10 se pasan esperando a que la máquina arranque |
| **Qué demuestra** | Lo heredado no tiene por qué contenerizarse para moverse: una VM migrada se publica al mundo exterior por el mismo ingress y dominio que una aplicación en contenedor |
| **Qué necesitarás** | Acceso al panel del tenant, el `~/.kube/workshop` del tenant, `kubectl`, `virtctl` |

## Por qué esto importa

El directorio de personal es la parte más antigua de «Propusk». Una aplicación de 2011, escrita por un contratista que ya no está. Se ejecuta sobre Windows Server y sobre una versión de .NET que nunca se actualizó, porque «funciona». No hay código fuente, ni documentación: solo una guía de recuperación de cuatro páginas con un paso que dice «llamar a Sergei».

Por dentro es una pequeña aplicación web: sirve una página HTTP que lista a los empleados y sus números de teléfono. La gente la abre en un navegador; otros servicios le consultan datos.

Este directorio no va a pasar a un contenedor. No es un «todavía no»: es nunca. No se puede, físicamente, contenerizar una aplicación que nadie puede reconstruir. Y eso no es razón para saltarse la migración. La respuesta a «¿qué hacemos con lo que no se puede portar?» es: traerlo tal cual está, como una máquina virtual.

Pero mover no basta: el directorio tiene que ser visible desde fuera, igual que antes. En este lab levantaremos una máquina virtual junto a los contenedores y la publicaremos hacia el exterior **de la misma manera que una aplicación en contenedor**: a través del ingress y el nombre de dominio de la plataforma. Para la plataforma, la VM es una carga de trabajo más detrás de un dominio, y no tiene por qué importarle si detrás hay un contenedor o un sistema operativo entero.

## Mini-glosario

| Término | Qué es | Como… pero |
|---|---|---|
| **VMInstance** | Una máquina virtual como objeto del clúster | **Una máquina virtual**, pero descrita como texto y creada con el mismo `kubectl` que las aplicaciones |
| **VMDisk** | Un disco que existe por separado de la máquina | **Un vmdk**, pero un objeto aparte: sobrevive a la máquina y puede adjuntarse a otra |
| **Instance type** | Un tamaño de máquina predefinido de la lista de la plataforma: tantos vCPU, tanta memoria | más cercano a los instance types de la nube que a ajustar vCPU/RAM a mano |
| **Instance profile** | Un conjunto de dispositivos y controladores para el sistema operativo invitado | **Guest OS type**, pero afecta a qué controladores verá el invitado |
| **cloud-init** | Un script de aprovisionamiento de primer arranque que se ejecuta la primera vez que se enciende la máquina | **Customization Specification**, pero YAML plano dentro del manifiesto en vez de un asistente en la UI |
| **Service** | Una dirección estable para un grupo de Pods dentro del clúster | **Un pool de load balancer**, pero la plataforma mantiene al día la lista de miembros por sí misma, por etiqueta |
| **Ingress** | Una regla: qué dominio se enruta a qué Service, junto con HTTPS | **Un proxy inverso frente a una granja** (nginx, HAProxy), pero descrito como un objeto, con el dominio y el certificado emitidos por la plataforma |
| **dominio** | Un nombre permanente por el que el servicio es visible desde fuera por HTTP | **Un nombre DNS detrás de un load balancer corporativo**, pero sin ningún ticket que abrir a DNS ni para un certificado |
| **KubeVirt** | El mecanismo por el que Kubernetes ejecuta VMs | **Un hipervisor**, pero no es un segundo hipervisor: por debajo es el mismo QEMU/KVM que usa cualquier Linux |

## Qué hay en la carpeta del lab

Ya tienes todos los archivos: los recibiste junto con el repositorio. No hay nada que crear ni volver a teclear: dondequiera que más abajo diga `kubectl apply -f name.yaml`, el archivo viene de aquí.

```bash
cd labs/12-vm
```

| Archivo | Qué es | Cuándo lo necesitarás |
|---|---|---|
| `staff-directory-vm.yaml` | La máquina virtual del directorio de personal heredado | lo aplicas **en el tenant** |
| `check.sh` | Una comprobación de que el directorio está publicado y responde en su dominio | lo ejecutas al final del lab |

📍 **El ingress lo crea el instructor, no el participante, y por adelantado.** Cada tenant ya contiene un `Service spravochnik-http` (reenvía el puerto 80 al 8080 y selecciona los Pods de tu máquina) y un `Ingress spravochnik` con el host `spravochnik.workshopXX.workshop.aenix.io`. No necesitas configurarlos ni guardar sus archivos tú mismo: todo lo que necesitas es levantar una máquina virtual llamada `spravochnik`, y la publicación la recogerá por sí sola.

## Paso 1. Levantar la VM

📍 **Dónde:** en el navegador, en el panel del tenant.

La VM es un servicio gestionado de Cozystack; vive en tu tenant. Se crea en dos movimientos, y conviene entenderlo desde ya.

### Primero el disco

Tenant → **Create application** → `VM Disk`.

| Campo | Valor | Por qué |
|---|---|---|
| Nombre | `spravochnik` | así se llamará también la máquina |
| Source | `Image` → `ubuntu-22.04` | tomada de la colección de imágenes lista de la plataforma |
| Storage | `20Gi` | la imagen `ubuntu-22.04` se descomprime a 20Gi, menos no se puede indicar |
| Storage class | `replicated` | tres copias de los datos en nodos distintos |

**Por qué el disco es un objeto aparte y no un campo dentro de la máquina.** Porque el disco sobrevive a la máquina. Puedes borrar la máquina entera, recrearla con otro tipo, otra red, otro nombre, y adjuntar el mismo disco. En vSphere haces lo mismo cuando desconectas un vmdk de una VM y lo conectas a otra; aquí está expresado de forma explícita en el modelo.

⚠️ **El disco no puede ser más pequeño que la imagen de origen.** La `ubuntu-22.04` de la plataforma se descomprime a 20Gi, y la plataforma rechazará una solicitud de un disco de 10Gi: no hay dónde clonar la imagen en un volumen más pequeño. Quedarse corto aquí sale más caro que pasarse: un disco se puede agrandar después, pero no encoger.

Espera a que el disco se llene: la plataforma descarga y descomprime la imagen, lo que toma un minuto o dos.

### Luego la máquina

Tenant → **Create application** → `VM Instance`.

| Campo | Valor | Por qué |
|---|---|---|
| Nombre | `spravochnik` | |
| Instance type | `u1.medium` | 1 CPU, 4 GB — la misma lista de tamaños que usan los nodos del clúster |
| Instance profile | `ubuntu` | el conjunto de dispositivos para el sistema operativo invitado |
| Run strategy | `Always` | mantenerla en marcha; si se apaga sola, se volverá a arrancar |
| Disks | `spravochnik` | el disco que creaste |
| Cloud init | ver abajo | levanta el directorio en el puerto 8080 |

En el campo cloud-init:

```yaml
#cloud-config
password: ubuntu
chpasswd: { expire: false }
ssh_pwauth: true
write_files:
  - path: /opt/directory/index.html
    content: |
      <!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Справочник</title></head><body><h1>Справочник сотрудников</h1><ul><li>Иванов И. — 101</li><li>Петров П. — 102</li></ul></body></html>
  - path: /etc/systemd/system/directory.service
    content: |
      [Unit]
      Description=Staff directory
      After=network.target
      [Service]
      ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /opt/directory
      Restart=always
      [Install]
      WantedBy=multi-user.target
runcmd: [ "systemctl daemon-reload", "systemctl enable --now directory" ]
```

Este cloud-init convierte el directorio en un servidor: coloca una página HTML con la lista de empleados y configura un servicio que la sirve por HTTP en el puerto 8080. `python3` ya viene en la imagen de Ubuntu, así que no hay nada que instalar ni se requiere internet. El puerto 8080 no se eligió al azar: es exactamente el puerto al que mira el `Service spravochnik-http`, creado por el instructor por adelantado.

⚠️ **Una contraseña en texto plano, solo para el lab.** En una máquina real aquí habría `sshKeys` y ninguna contraseña. Tomamos el camino corto para no gastar tiempo del taller intercambiando claves.

**Lo mismo como texto.** Ambos objetos, el disco y la máquina, están en un solo archivo, `staff-directory-vm.yaml`, y se crean con un único comando: primero el disco, luego la máquina. Antes de aplicar, abre el archivo y reemplaza el marcador `tenant-workshopXX` que hay en él por el nombre de tu propio tenant; de lo contrario los objetos acabarán en el lugar equivocado.

```bash
# KUBECONFIG es la variable de la que kubectl lee la dirección del clúster y los datos de acceso.
# Aquí necesitas el archivo de acceso al TENANT: la VM vive en el tenant, en el clúster de gestión.
export KUBECONFIG=~/.kube/workshop
# apply = «llevar el clúster a lo que está escrito en el archivo». Si no hay objetos, los crea;
# si los objetos ya existen, los lleva al estado descrito.
#   -f   leer la descripción desde un archivo
kubectl apply -f staff-directory-vm.yaml
```

**Lo que deberías ver:** dos líneas con `created`, una para el disco y otra para la máquina.

<details>
<summary><b>Una mirada más de cerca: qué hay dentro de staff-directory-vm.yaml</b></summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: VMDisk
```

El mismo grupo de API en el que viven los buckets, las bases de datos y las colas. Aquí la máquina virtual no es un subsistema aparte con su propia interfaz, sino un objeto del catálogo igual que Redis. Esta es la sustancia detrás de la frase «en una interfaz y a través de una API».

```yaml
spec:
  source:
    image:
      name: ubuntu-22.04
  storage: 20Gi
```

Un nombre de imagen de la colección compartida de la plataforma, no una URL: la colección se comparte en todo el clúster, y la imagen se descarga una sola vez. `storage` no puede ser más pequeño que la propia imagen: `ubuntu-22.04` se descomprime a 20Gi. Si necesitas tu propia imagen, en ese mismo lugar están `source.http` con un enlace y `source.disk` para clonar un disco existente.

```yaml
kind: VMInstance
spec:
  instanceType: u1.medium
```

El tamaño de la máquina se toma de una lista predefinida, no se ajusta con campos de vCPU y RAM. `u1.medium` es 1 CPU y 4 GB. La misma lista se usa cuando pides un nodo para un clúster de Kubernetes, y no es casualidad: un nodo del clúster es un VMInstance igual que este.

```yaml
  instanceProfile: ubuntu
```

El perfil del sistema operativo invitado: qué controladores, drivers y dispositivos entregar a la máquina para que el invitado los reconozca. El análogo más cercano es «Guest OS type» al crear una VM en vSphere, y las consecuencias son las mismas: un perfil equivocado te da una máquina que arranca pero no ve su disco.

```yaml
  runStrategy: Always
```

El estado de energía deseado. `Always`: mantenerla en marcha; si el invitado se apaga desde dentro, la máquina se vuelve a arrancar. `Halted`: apagada. `Manual`: se deja como está, nadie interviene. Fíjate en la formulación, es la misma que `replicas` en un Deployment: no «enciéndela», sino «mantenla encendida».

```yaml
  disks:
    - name: spravochnik
```

Una lista de discos por nombre de objeto VMDisk. Un segundo disco para datos se agrega aquí mismo, como una segunda línea.

```yaml
  cloudInit: |
    #cloud-config
    write_files:
      - path: /opt/directory/index.html
      - path: /etc/systemd/system/directory.service
    runcmd: [ "systemctl daemon-reload", "systemctl enable --now directory" ]
```

cloud-init es el mecanismo estándar de aprovisionamiento de primer arranque que entiende toda imagen de Linux para la nube. Se ejecuta una vez, en el primer encendido. Aquí hace tres cosas: coloca la página HTML del directorio, configura un servicio systemd que sirve esa página por HTTP en el puerto 8080, y arranca el servicio. Es el análogo de una Customization Specification en vSphere, solo que es texto dentro del manifiesto en lugar de un asistente en la UI, lo que significa que vive en Git y se revisa junto con todo lo demás.

Es precisamente gracias a este bloque que el directorio se vuelve visible desde fuera: el `Ingress` que el instructor creó por adelantado enruta el dominio a `Service spravochnik-http`, y este a su vez al puerto 8080 dentro de la máquina. En cuanto el servicio en el 8080 se levanta, la publicación lo recoge por sí sola.

### Lo que este manifiesto no tiene, y no tendrá

**Un campo `replicas`.** `VMInstance` no tiene uno. Una máquina virtual es un objeto único; si necesitas dos máquinas, creas dos objetos con nombres distintos.

Esta es una diferencia fundamental respecto a un `Deployment`, y no es un defecto. Las copias en un Deployment son intercambiables: cualquiera de ellas atenderá cualquier petición, y perder una no es gran cosa. Las máquinas virtuales no son intercambiables: cada una tiene su propio estado en su propio disco, y «haz otra igual» significa algo completamente distinto que para un contenedor.

La consecuencia práctica: **la autoreparación que viste en el lab de borrado de Pods no existe para una VM.** Borra un Pod y el clúster crea uno nuevo en segundos. Borra un VMInstance y la máquina desaparece, y la única forma de recuperarla es a mano, adjuntando el disco que sobrevivió. Aquí estás exactamente en el mismo lugar en que estabas en vSphere, y conviene saberlo de antemano en vez de descubrirlo por el camino.

</details>

El primer encendido toma de 3 a 5 minutos: cloud-init expande el sistema de archivos por todo el disco y levanta el servicio del directorio. No nos quedaremos de brazos cruzados esperándolo: en el siguiente paso comprobaremos qué está pasando exactamente con la publicación mientras la máquina aún arranca.

## Paso 2. Tocar a la puerta del dominio mientras la máquina arranca

📍 **Dónde:** en tu laptop, en una ventana de terminal aparte. O directamente en el navegador.

El instructor ha publicado el directorio por adelantado: tu tenant ya tiene un `Ingress spravochnik` con el host `spravochnik.workshopXX.workshop.aenix.io` y un `Service spravochnik-http` que enruta al puerto 8080 dentro de la máquina. La publicación está lista para recibir el directorio en cuanto empiece a responder. Comprobémoslo ahora mismo, sin esperar a que la máquina termine de cargar.

```bash
# curl — «ve a la dirección y muestra la respuesta». Reemplaza XX por tu propio número de tenant.
#   --max-time 5   rendirse tras 5 segundos en vez de esperar mucho rato
curl --max-time 5 http://spravochnik.workshopXX.workshop.aenix.io
```

**Lo que verás:**

```
<html><head><title>503 Service Temporarily Unavailable</title></head>
<body><center><h1>503 Service Temporarily Unavailable</h1></center></body></html>
```

> **Detente y piensa antes de seguir leyendo.**
>
> El instructor creó el ingress, el dominio está configurado, y tú levantaste la máquina.
> ¿Por qué el dominio responde `503` en vez de la página del directorio?

<details>
<summary><b>La respuesta, y una lección más amplia que este error</b></summary>

Porque el directorio dentro de la máquina aún no está escuchando.

`503` no significa «el ingress está roto». El ingress está en su sitio y sabe a dónde enrutar el tráfico: a `Service spravochnik-http`, que selecciona los Pods de tu máquina y reenvía la petición al puerto 8080. Pero mientras cloud-init expande el sistema de archivos y configura el servicio, todavía nadie responde en el 8080 dentro de la máquina: el service no tiene ni un solo backend listo. Y eso es exactamente lo que reporta el ingress: la ruta existe, pero aún no hay nadie que responda en ella.

El código de respuesta aquí es el diagnóstico en sí mismo:

| Lo que ves | Qué significa |
|---|---|
| `503` | el ingress está en su sitio, pero no hay backend listo detrás |
| `404` | el ingress existe, pero la regla enruta al service equivocado |
| sin respuesta, se agota el tiempo de espera | no se creó ningún ingress con este host |

**La lección es más amplia que este error.** Un `503` de un ingress trata de la disponibilidad del backend, no del ingress en sí. Obtendrás el mismo `503` si la aplicación detrás del dominio se cae o si su Pod aún no ha pasado su comprobación de readiness. Publicar hacia el exterior y la disponibilidad de la carga de trabajo son dos cosas distintas: el dominio se configura por adelantado y está vacío durante un rato, llenándose exactamente cuando aparece detrás alguien listo para responder. Para una VM eso es «cuando el servicio en el 8080 se levantó»; para un contenedor es «cuando el Pod pasó readiness». El mecanismo es el mismo, y ese es el significado de la frase «una VM se publica de la misma manera que una aplicación en contenedor».

</details>

## Paso 3. Entrar en la máquina

📍 **Dónde:** en el panel, en la ficha de la máquina `spravochnik`.

La ficha tiene una consola: es la misma pantalla que «Open Console» en vSphere. Ábrela. Usuario `ubuntu`, contraseña `ubuntu`.

⚠️ **Si la consola muestra una pantalla negra y un cursor parpadeante, espera.** cloud-init aún no ha terminado, y el prompt aparecerá por sí solo. No reinicies la máquina: un reinicio en medio de cloud-init la deja configurada a medias.

**El mismo acceso desde la terminal.** `virtctl` es un comando aparte para trabajar con máquinas virtuales: consola, reenvío de puertos, encender y apagar. Se instala como un único archivo; cómo exactamente está escrito en `workshop/README.md`.

Vale la pena repasar de antemano una peculiaridad de su sintaxis, o tu primerísimo comando volverá denegado. El objetivo de `virtctl` no se da como un nombre a secas, sino con un prefijo de tipo: `vmi/<name>`. `vmi` es virtual machine instance, la **instancia en ejecución** de la máquina; el objeto `VMInstance` que creaste y la instancia en ejecución son dos objetos distintos en la API. Bajo el acceso de tenant los permisos se otorgan sobre el **subrecurso** `virtualmachineinstances` (`console` y `portforward`), no sobre los objetos `virtualmachines` completos: un nombre a secas llega al objeto vm y vuelve `forbidden`. La plataforma construye el nombre de la instancia a partir del prefijo `vm-instance-` más el nombre de tu máquina: `spravochnik` es la instancia `vm-instance-spravochnik`.

```bash
# acceso de tenant: la máquina vive en el tenant
export KUBECONFIG=~/.kube/workshop
# console = conectarse a la consola serie de la máquina. Es la misma pantalla que
# «Open Console» te da en vSphere, solo que en modo texto:
#   --namespace  en qué sección del clúster mirar; para tu tenant se llama
#                tenant- más tu login, reemplaza XX por tu propio número
#   vmi/...      el objetivo: la instancia en ejecución de la máquina, no la descripción VMInstance
virtctl console --namespace=tenant-workshopXX vmi/vm-instance-spravochnik
```

Si la pantalla está en blanco tras conectar, pulsa Enter y aparecerá el prompt de login. Para salir de la consola, `Ctrl+]`. Los nombres de todas las instancias en ejecución de tu tenant los muestra `kubectl --kubeconfig ~/.kube/workshop get vminstance -n tenant-workshopXX`.

Por dentro es un Ubuntu corriente. Asegúrate de que el directorio se ha levantado:

```bash
uname -a                       # kernel y arquitectura: la misma línea que en un servidor bare-metal
systemctl status directory     # el servicio del directorio: debería estar active (running)
curl -s localhost:8080 | head  # la misma página, pero solicitada desde dentro de la propia máquina
```

Si `systemctl status directory` muestra `active (running)` y el `curl` a `localhost:8080` devolvió el HTML con la lista de empleados, el servidor está listo, y la publicación de cara al exterior está a punto de cambiar el `503` por la página. No hay ni rastro de Kubernetes dentro, y no debería haberlo: el invitado no sabe que está en un clúster, exactamente igual que una VM en vSphere no tiene por qué saber de vCenter.

## Paso 4. El dominio responde: el directorio está publicado

📍 **Dónde:** en tu laptop. O en el navegador.

La misma petición que devolvió `503`, pero ahora el servicio en el 8080 se ha levantado. Sustituye tu propio número.

```bash
curl http://spravochnik.workshopXX.workshop.aenix.io
```

**Lo que deberías ver**: el HTML de la página del directorio:

```html
<h1>Справочник сотрудников</h1><ul><li>Иванов И. — 101</li><li>Петров П. — 102</li></ul>
```

Abre esta dirección en un navegador y verás la misma lista. El directorio es visible desde fuera por un nombre de dominio amigable, con HTTPS de la plataforma, sin un solo ticket a redes ni para un certificado.

**Desglosemos lo que acaba de pasar.**

Una máquina virtual Ubuntu que no sabe nada de Kubernetes está escuchando en HTTP corriente en un puerto corriente. Desde fuera se llega a ella por el dominio `spravochnik.workshopXX.workshop.aenix.io`, y la petición viaja hasta ella a través del mismo ingress que publica las aplicaciones en contenedor. Sin agentes dentro del invitado, sin pasarelas, sin «integración». Para la publicación no hay diferencia entre lo que hay detrás del dominio, un Pod de nginx o una máquina virtual entera: ve un `Service`, detrás del `Service` hay un backend listo, y con eso basta.

Esto es exactamente lo que significa «lo heredado no tiene por qué contenerizarse». El directorio de 2011 seguirá funcionando como siempre lo hizo, y desde fuera se ve igual que cualquier servicio nuevo de «Propusk»: un nombre, un dominio, HTTPS.

## Verificación

📍 **Dónde:** en tu laptop, en la misma ventana de terminal donde trabajaste con `kubectl`.

El script no comprueba la presencia de objetos, sino el funcionamiento en esencia: el nombre de dominio devuelve un `200` y es la página del directorio, la máquina misma está en marcha, y el `Ingress` que la publica está en su sitio. La comprobación por dominio funciona incluso sin acceso de tenant: le basta con `curl`; el acceso de tenant añade las comprobaciones del estado de la máquina.

```bash
# acceso de tenant: de aquí el script toma la propia VM y el Ingress
export KUBECONFIG=~/.kube/workshop
# tu login sin la palabra tenant-: de él el script construye tanto el nombre de la sección tenant-workshopXX
# como el nombre de dominio spravochnik.workshopXX.workshop.aenix.io
export COZY_TENANT=workshopXX
# el ./ antes del nombre significa «el archivo de la carpeta actual», es decir, de labs/12-vm
./check.sh
```

⚠️ **En Windows el script se ejecuta desde WSL**, no desde PowerShell; cómo instalarlo está escrito al inicio del lab 0. Sin WSL igual puedes completar el lab, pero no habrá informe de artefacto.

`COZY_TENANT` es obligatorio: sin él el script se detiene de inmediato, pues el dominio se construye a partir de él. Si no está configurado el acceso de tenant, las comprobaciones del estado de la máquina se omiten con una advertencia, mientras que la comprobación principal, la respuesta en el dominio, se ejecuta igual.

## Limpieza

Deja la máquina virtual si tienes previsto el lab de monitoreo: su consumo también aparece en los gráficos, y sirve de buena ilustración. Si no, borra la máquina y el disco a través del panel.

⚠️ **Borra en el orden correcto: primero la máquina, luego el disco.** Un disco adjunto a una máquina en marcha no se borrará, y acabarás con un objeto atascado en estado de borrado.

El `Ingress` y el `Service` que publican el directorio los creó el instructor; no los toques, los necesitará el siguiente participante en este entorno de pruebas.

El costo de la limpieza aquí es, honestamente, mayor que en los otros labs: un disco con datos es un disco con datos, y no se desvanece al instante. Por otro lado, crearlo no requirió ni un ticket de espacio en disco ni una aprobación.

## Lo que ya sabemos hacer

- Levantar una máquina virtual en un tenant, con el ratón y como texto
- Explicar por qué el disco y la máquina son dos objetos, y qué se gana con ello
- Publicar una carga de trabajo hacia el exterior a través de ingress y un dominio, de la misma manera que un contenedor
- Leer un `503` de un ingress como «aún no hay nadie que responda detrás del dominio», no como una avería
- Mostrar con un ejemplo en vivo que migrar lo heredado no requiere reescribirlo

## Y en vSphere esto sería

Una VM en vSphere es terreno conocido, y allí se crea de la forma habitual. La diferencia no es la máquina en sí, sino exponerla al exterior bajo un nombre amigable.

Para publicar esta máquina en un dominio en vSphere, necesitarías un proxy inverso o un load balancer como producto aparte, un ticket a redes para una dirección externa, un ticket a DNS para el nombre, y un ticket a seguridad para el certificado. Tres o cuatro comandos, tres o cuatro sistemas, y la pregunta general de «quién opera todo esto». Aquí la publicación es un objeto `Ingress` que el instructor configuró por adelantado, y un dominio que se llena en el segundo en que la máquina empieza a responder.

**Dónde vSphere es más cómodo, honestamente.** Cuando se trata de gestionar las máquinas virtuales en sí, vCenter sigue siendo más rico, y no tiene sentido fingir lo contrario:

| Qué | vSphere | Cozystack |
|---|---|---|
| Plantillas y clonado | maduro, con personalización del invitado | el clonado de discos está, un asistente de personalización no |
| Instantáneas | familiares, con árbol | presentes, pero el ecosistema a su alrededor es más joven |
| Migración en vivo | vMotion, refinado durante años | presente, pero se usa con menos frecuencia y está menos probado en batalla |
| Permisos sobre una carpeta de VMs | granulares | permisos a nivel de tenant, sin carpetas |
| Consola y herramientas del invitado | VMware Tools con telemetría completa | qemu-guest-agent, menos datos |

Si necesitas **solo** máquinas virtuales, la respuesta honesta es que moverse por moverse no tiene sentido. El beneficio aparece donde necesitas algo más junto a las VMs: clústeres, bases de datos, colas, registries, almacenamiento de objetos, publicación en un dominio. Entonces, en lugar de cinco productos con cinco modelos de permisos, tienes un catálogo, y el directorio de 2011 está en él junto a todo lo demás.
