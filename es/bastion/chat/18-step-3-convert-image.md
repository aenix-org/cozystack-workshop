## 18. Paso 3: conversión de la imagen

**Convertimos una imagen de VMware en una imagen para KVM**

📍 **Dónde:** dentro de la máquina conversora a la que acabas de entrar por la consola. No en el bastion.

📄 Trabajamos con `scripts/convert.sh`. Esta máquina sí tiene acceso a la red, así que descargará el
archivo por su cuenta — no hace falta copiar nada por el portapapeles.

Trae el script desde GitHub directamente a la máquina:
```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/convert.sh
```

Ábrelo:
```bash
nano convert.sh
```

**Aquí es donde te sirven los tres valores que anotaste en el paso 1.** Cerca del inicio del
archivo hay un bloque titulado «PEGA TUS VALORES» — reemplaza en él los marcadores por los
tuyos, dejando las comillas en su lugar:

```
BUCKET="your-bucket-name"
ACCESS_KEY="your-accessKey"
SECRET_KEY="your-secretKey"
```

No toques la línea `S3_ENDPOINT` ni el enlace a la imagen de origen — ya están correctos
y son iguales para todos.

Para guardar en nano: `Ctrl+O`, luego `Enter`, y después `Ctrl+X` para salir. Comprueba que no
queden marcadores:
```bash
grep ВСТАВЬТЕ convert.sh || echo "all filled in, ready to run"
```

Ejecútalo — siempre a través de `sudo`, el script necesita privilegios de root. Y ejecútalo **dentro de `screen`**:
la conversión tarda unos cinco minutos, y ahora mismo estás sobre una cadena de dos conexiones (tu portátil → SSH
al bastion → la consola de la máquina conversora). Si cualquier eslabón de la cadena se cae, una ejecución
normal se cortaría a la mitad. `screen` mantiene vivo el proceso incluso cuando la conexión se cae:

```bash
screen -S convert          # entrar en una sesión aparte
sudo bash convert.sh       # ejecutarlo dentro de ella
#  ¿se cayó la conexión? vuelve a entrar a esta misma máquina, luego:  screen -r convert
```

Lo que ocurre por dentro: el script descarga la imagen de origen, ejecuta `virt-v2v`,
comprime el resultado y lo sube a tu bucket.

El trabajo más importante lo hace `virt-v2v`. No solo cambia el formato del archivo: introduce
los controladores virtio dentro del sistema invitado y arregla el gestor de arranque. Sin esto, la máquina
no arrancará en absoluto en el nuevo hipervisor.

⏳ **Esto tardará unos cinco minutos.** Nuestro entorno de pruebas no tiene virtualización anidada,
así que la conversión corre en modo de emulación. El progreso se ve en la consola — no la cierres.

Al final el script imprimirá un **enlace prefirmado** a tu imagen — busca en la salida una línea
que empiece con la palabra `Share:`, el enlace va justo después.

**Qué hacer con él:** cópialo en ese mismo bloc de notas. En el siguiente paso volverás al bastion, abrirás `manifests/03-app-vm.yaml` y lo pegarás en el campo `url` — donde
ahora está el marcador `ВСТАВЬТЕ_PRESIGNED_URL`. El mismo del que te avisé
cuando estábamos rellenando los números.

Es un enlace firmado temporal: el almacenamiento no está expuesto al exterior, y el enlace lo generaste
con tus propias claves. Vive una semana — de sobra para el taller y para experimentar después.
