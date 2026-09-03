## 21. Paso 4: tu máquina virtual

**Levantamos una máquina a partir de tu propia imagen**

📍 **Dónde:** en tu laptop.

⚠️ **Primero, apaga la máquina conversora** — ya cumplió su función y está reteniendo 8Gi de tu cuota.
Si no la eliminas, la nueva máquina quedará colgada en `Pending`, y parecerá
que el entorno de pruebas está averiado. En talleres anteriores casi todos se quedaron atascados aquí:

```bash
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```

La imagen permanece en el bucket — es justo desde donde levantaremos la máquina.

Ahora abre `manifests/03-app-vm.yaml`, pega el enlace prefirmado en el campo `url`
y aplícalo:

```bash
kubectl apply -f manifests/03-app-vm.yaml
kubectl get vminstance -n tenant-workshopXX -w
```

Primero el clúster descarga la imagen desde el enlace y la reparte entre las réplicas — esto toma un minuto o dos.
Después la máquina arranca.

Entramos:
```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```

**Acceso a tu máquina:**
```
login:    root
password: cozydemo
```

Para salir de la consola — `Ctrl+]`.

**Aquí tienes el mismo par de objetos que con la máquina conversora**, solo que el disco no se toma
del catálogo, sino que se descarga desde tu enlace:

• **VM Disk** `app-1` — 10Gi, source = http, esa misma URL prefirmada
• **VM Instance** `app-1` — perfil `centos.7`, instance type `u1.medium`

Los nombres coinciden, y está bien: el disco y la máquina son tipos de objeto distintos. En los comandos
`virtctl` la máquina, como la vez anterior, se referencia con su prefijo: **`vm-instance-app-1`**.

🖱 **A través del panel:** **1)** **VM Disk → Deploy new**: nombre `app-1`, source = **http**,
en el campo URL — el enlace prefirmado, tamaño `10Gi`, storage class `replicated`.
**2)** **VM Instance → Deploy new**: nombre `app-1`, instance type `u1.medium`,
profile `centos.7`, disco — `app-1`. La consola — el botón **VNC** en la página de la máquina.

Fíjate en lo que acabas de hacer: describiste una máquina virtual en texto
y la aplicaste con un solo comando. Puedes colocar este archivo en un repositorio y levantar
cien máquinas iguales sin hacer un solo clic.
