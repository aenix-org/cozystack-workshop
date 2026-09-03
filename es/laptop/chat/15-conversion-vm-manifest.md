## 15. Una mirada de cerca: qué hay dentro de 02-conversion-vm.yaml

El archivo contiene **dos** objetos, separados por una línea `---`. Así es como YAML empaqueta
varios documentos en un solo archivo. Una máquina virtual no puede existir sin un disco, así que
el disco se describe por separado y siempre se crea primero.

```yaml
kind: VMDisk
metadata:
  name: convert-tools
spec:
  source:
    image:
      name: ubuntu-20.04
  storage: 25Gi
  storageClass: replicated
```

`kind: VMDisk` — el disco por sí solo, un objeto aparte. A esto hay que acostumbrarse: en
vSphere un disco es una propiedad de la máquina, aquí es una entidad independiente que puedes
crear de antemano, conectar a una máquina, desconectar y conectar a otra.

`source.image.name: ubuntu-20.04` — de dónde tomar el contenido. Es ese mismo catálogo de
imágenes del mapa de arriba: Cozystack ya descargó de `cloud-images.ubuntu.com` la imagen cloud
oficial de Ubuntu 20.04 y la mantiene localmente. Aquí le pedimos que haga una copia de ella.
Nadie sale a internet a buscarla; la copia se hace dentro del clúster.

⚠️ **La versión de Ubuntu está indicada a propósito: no la cambies.** En 24.04 la máquina no
arranca; en 22.04 el reempaquetado tropieza con la vieja base de datos de paquetes RPM dentro de
CentOS 7 — `virt-v2v` no puede analizarla. Probado para que tú no tengas que hacerlo.

`storage: 25Gi` — el tamaño del disco. La imagen de Ubuntu del catálogo ocupa 20Gi, y **el disco
debe ser más grande que la imagen**, de lo contrario la copia se interrumpe a la mitad y el disco
luego queda colgado en estado `Terminating` y estorba. El margen también hace falta porque dentro
estarán al mismo tiempo el `app-1.ova` descargado y el resultado del reempaquetado.

`storageClass: replicated` — cómo almacenarlo. `replicated` significa varias copias en distintos
nodos: se cae un nodo — los datos siguen ahí. El análogo es una política de almacenamiento en
vSphere. También existe `local` — más rápido, pero vive en un solo nodo.

```yaml
kind: VMInstance
metadata:
  name: convert
spec:
  instanceType: u1.large
  instanceProfile: ubuntu
  runStrategy: Always
  disks:
    - name: convert-tools
```

`instanceType: u1.large` — el tamaño de la máquina, un paquete predefinido de «tantos CPU, tanta
memoria»: aquí dos CPU y ocho gigabytes. El reempaquetado mantiene la imagen en memoria por
fragmentos y la exige en serio.

`instanceProfile: ubuntu` — un conjunto de ajustes de hardware virtual adaptados a este sistema
huésped: qué controladores de disco, qué tarjeta de red, cómo se pasa el reloj. El análogo más
cercano es el «Guest OS Type» del asistente de creación de VM, que igualmente cambia en silencio
una docena de ajustes para adaptarse al sistema elegido.

`runStrategy: Always` — mantener la máquina encendida y, si se cae, volver a levantarla. Esto no
es «arranque automático al iniciar el host», sino una regla permanente: la plataforma se asegura
de que la máquina esté en ejecución.

`disks` — qué discos conectar. Una referencia por nombre al objeto `VMDisk` descrito arriba.

```yaml
  cloudInit: |
    #cloud-config
    password: ubuntu
    packages: [ libguestfs-tools, virt-v2v, qemu-utils ]
    runcmd:
      - [ bash, -c, "wget ... mc && chmod +x /usr/local/bin/mc" ]
```

`cloudInit` — instrucciones que la máquina ejecuta por sí sola en el primer arranque. Es el
mecanismo estándar de toda imagen cloud: al iniciar, el sistema busca ese texto y lo ejecuta. En
vSphere el análogo más cercano es una Customization Specification, solo que aquí se expresa como
texto y está en el mismo archivo que la propia máquina.

Aquí le pedimos que establezca una contraseña, instale `virt-v2v` con sus dependencias y descargue
`mc` — un cliente de consola para trabajar con almacenamiento S3, el mismo que usaremos para subir
el resultado al bucket.

⚠️ **La contraseña en texto plano** — solo para el entorno de pruebas de entrenamiento: la máquina vive media
hora y solo es accesible desde dentro del clúster. En una máquina real pones claves ssh en lugar
de `password`.
