## 14. Paso 1: tu propio almacenamiento

**Crear un bucket para la imagen**

📍 **Dónde:** en el bastion, en el directorio `~/workshop`.

La imagen de disco pesa varios gigabytes. Tiene que vivir en algún lugar para que luego el clúster pueda descargar el archivo mediante un enlace. Para eso sirve el almacenamiento de objetos: el mismo principio que S3.

```bash
kubectl apply -f manifests/01-bucket.yaml
kubectl get buckets.apps.cozystack.io -n tenant-workshopXX
```

Espera a que el bucket pase a un estado funcional.

El manifiesto crea un bucket llamado **`my-images`** con un único usuario: `app`. En el panel aparece en la sección **Bucket**.

🖱 **A través del panel:** **Bucket → Deploy new**, nombre `my-images`. Eso sí, asegúrate de **agregar el usuario `app` a la sección `users` de inmediato**, antes de crearlo. Si creas un bucket vacío y agregas el usuario después mediante Edit, el bucket queda a medio terminar y la subida de la imagen fallará. El manifiesto ya se encarga de esto.

**Ahora toma las claves del bucket: las vas a necesitar dentro de dos pasos.**

El bucket está cerrado y, para poner algo en él, necesitas sus propias claves de acceso. Están en el panel: **Bucket → `my-images` → pestaña Secrets → el secret `bucket-my-images-app-credentials`**. Despliégalo y verás cuatro valores, cada uno con un botón *Reveal* y otro *Copy*.

**Qué hacer con ellos ahora mismo: copia tres de ellos en un bloc de notas** — en cualquiera, ya sea en las notas o en un borrador de mensaje para ti mismo:

• `bucketName`
• `accessKey`
• `secretKey`

⚠️ **`bucketName` NO es `my-images`.** `my-images` es el nombre que le diste al pedido; el nombre real del bucket en S3 lo generó la propia plataforma, largo, del tipo `bucket-a9209f83-4ac1-463e-8477-d8365bef787b`. Eso es exactamente lo que va al script, del campo `bucketName`. Si pones `my-images`, la subida irá a un bucket inexistente y fallará con `Insufficient permissions`. En talleres anteriores la gente se ha tropezado con esto.

El cuarto, `endpoint`, no hace falta que lo anotes: es el mismo para todos y ya está escrito en el script.

**A dónde van.** En el paso 3 abrirás el archivo `convert.sh` en la máquina conversora, y dentro de él un bloque «PEGA TUS VALORES» de tres líneas:

```
BUCKET="ВСТАВЬТЕ_bucketName"
ACCESS_KEY="ВСТАВЬТЕ_accessKey"
SECRET_KEY="ВСТАВЬТЕ_secretKey"
```

Esos son exactamente los tres valores que pegarás ahí, cada uno entre sus propias comillas. No los necesitarás en ningún otro lado: el propio script subirá la imagen terminada a tu bucket y creará él mismo un enlace hacia ella.

⚠️ La clave secreta es la contraseña de tu almacenamiento. No la envíes al chat común, ni siquiera cuando pidas ayuda. Si algo no cuadra, escríbeme en privado.

⚠️ Si decides cambiar `endpoint` por el tuyo: en el panel se muestra sin esquema (`s3.workshop.aenix.io`), pero en el script se escribe **con** `https://` al inicio. Si no lo pones, la subida fallará en silencio.
