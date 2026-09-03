## 13. En detalle: qué hay dentro de 01-bucket.yaml

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Bucket
metadata:
  name: my-images
  namespace: tenant-workshopXX
spec:
  users:
    app: {}
```

`apiVersion: apps.cozystack.io/v1alpha1` — de qué conjunto de tipos se toma este objeto.
`apps.cozystack.io` es el catálogo de Cozystack en sí: todo lo que aparece ahí es algo que puedes
pedir. No es que «Kubernetes sepa manejar buckets por sí solo» — los añadió la plataforma.

`kind: Bucket` — qué es exactamente lo que pides. El archivo no describe *cómo* levantar el
almacenamiento: dice «quiero un bucket», y la plataforma hace todo lo demás por sí misma. Así funciona
todo el catálogo — escribes lo que necesitas, no una secuencia de pasos.

`metadata.name: my-images` — el nombre del pedido. Lo usarás para encontrarlo en el panel y
en los comandos. Este nombre es interno; la plataforma generará su propio nombre real de bucket en S3,
largo y único — lo verás más adelante en el parámetro `bucketName`.

`namespace: tenant-workshopXX` — tu porción de la plataforma. **El único sitio que tienes que cambiar a
mano:** sustituye `XX` por tu propio número. Un namespace es una partición dentro del clúster:
los objetos con el mismo nombre en distintos namespaces no se estorban entre sí ni se ven entre sí. La
analogía más cercana es un Resource Pool aparte con sus propios permisos de acceso, solo que más estricto.

`users: app: {}` — crea un usuario de S3 llamado `app`. Las llaves vacías significan «configuración por
defecto»: la plataforma inventará por sí misma una clave de acceso y una clave secreta para él y las
guardará en un objeto Secret aparte, que abrirás en el panel. No inventas ninguna contraseña ni la
escribes en ningún sitio.

Fíjate en lo que **no** está en el archivo: el tamaño, la dirección, los puertos, el certificado, los
nodos donde se ubicará todo esto. Todo eso lo determina la plataforma por sí misma. En eso consiste
precisamente la diferencia entre «pedir del catálogo» y «montarlo a mano».
