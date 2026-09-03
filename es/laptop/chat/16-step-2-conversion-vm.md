## 16. Paso 2: la máquina conversora

**Levantamos la VM en la que haremos la conversión**

📍 **Dónde:** en la laptop.

**Qué es la «conversión» y por qué no hay forma de evitarla.** El disco de una máquina virtual es un archivo. VMware lo guarda en su propio formato, `VMDK`. KVM, sobre el que se ejecutan las VMs en Cozystack, no entiende ese formato: necesita `QCOW2`. El contenido es el mismo, tu CentOS con todos sus adornos, pero el empaquetado es distinto. La conversión es reempaquetar el archivo de un formato a otro; los datos en sí no cambian.

Además de eso, hay que arreglar lo que hay dentro. Un sistema que creció en vSphere espera encontrar el hardware virtual de VMware: sus propias tarjetas de red, sus propias controladoras de disco, los drivers `vmxnet3` y `pvscsi`. En su nuevo hogar el hardware es distinto: `virtio`. Si no le deslizas los drivers correctos en la imagen de arranque de antemano, la máquina arranca y no encuentra ni disco ni red. De esto también se ocupa la conversión.

**Por qué una máquina aparte, y no tu propia laptop.** La herramienta se llama `virt-v2v`, arrastra una montaña de dependencias, se ejecuta bajo Linux y devora decenas de gigabytes. Instalarla en tu laptop de trabajo solo por una vez es mala idea, y en Windows y macOS no se ejecutará en absoluto. Es más fácil levantar una máquina desechable junto al almacenamiento, hacer el trabajo dentro y apagarla.

Como añadido, este es exactamente el enfoque que se usa para la conversión en proyectos reales de migración: la máquina conversora vive junto a los datos, no en la laptop de alguien a través de una VPN.

```bash
kubectl apply -f manifests/02-conversion-vm.yaml
kubectl get vminstance -n tenant-workshopXX -w
```

Esperamos el estado `Running` (presiona Ctrl+C para dejar de observar). Entramos **por la consola**:

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-convert
```

**Acceso a la máquina conversora:**
```
login:    ubuntu
password: ubuntu
```

Para salir de la consola: `Ctrl+]`. Si la pantalla está en blanco, presiona Enter.

⚠️ **No entres por `virtctl ssh`.** En talleres anteriores no le funcionó a nadie: responde `exit status 255` y corta la conexión. La consola pasa por la API del clúster y siempre funciona. Lo mismo está disponible con el ratón: el botón **VNC** en la página de la máquina en el panel.

**Qué creó exactamente este comando.** El archivo describe dos objetos, así que en el panel aparecerán dos entradas, no una:

• **VM Disk** con el nombre `convert-tools` — un disco de 25Gi, clonado de la imagen del catálogo `ubuntu-20.04`
• **VM Instance** con el nombre `convert` — la máquina en sí, que conecta ese disco

Una VM nunca existe sin disco; por eso el disco siempre se crea primero, como objeto aparte. Recuerda esto: en el paso 4 verás exactamente el mismo par.

⚠️ Y una palabra sobre los nombres de una vez, o te vas a confundir. El objeto en el panel se llama `convert`, pero la máquina que levanta se conoce dentro del clúster como **`vm-instance-convert`** — con el prefijo. Así que en el panel buscas `convert`, mientras que en los comandos de `virtctl` escribes `vm-instance-convert`.

🖱 **Por el panel:** creas los mismos dos objetos a mano, uno tras otro.
**1)** **VM Disk → Deploy new**: nombre `convert-tools`, source = **image**, imagen `ubuntu-20.04`, tamaño `25Gi`, storage class `replicated`.
**2)** **VM Instance → Deploy new**: nombre `convert`, instance type `u1.large`, profile `ubuntu`, y en la lista de discos eliges `convert-tools` — el que creaste un paso antes. Puedes entrar ahí mismo con el botón **VNC**, y entonces no hacen falta ni ssh ni virtctl, todo está en el navegador.

⚠️ Haz el disco no menor de 25Gi: si es más pequeño que la imagen, el clon no pasa, y luego el disco se queda colgado en estado Terminating y estorba.

⚠️ El manifiesto especifica deliberadamente la imagen **ubuntu-20.04**; no la cambies. En 24.04 la máquina no arranca, y en 22.04 la conversión tropieza con la vieja base de paquetes dentro de CentOS 7. Lo comprobamos para que tú no tengas que hacerlo.
