## 31. Cuando algo no funciona

**Una lista breve de las cosas con las que la gente tropieza**

• **La aplicación no es accesible desde afuera.** En un CentOS migrado, el culpable habitual
  es el firewall integrado: está bloqueando el puerto 8080:
  ```bash
  systemctl stop firewalld
  ```

• **`kubectl` responde «forbidden».** Verifica que estés hablando con tu propio namespace:
  `-n tenant-workshopXX`. Y recuerda que está disponible `vminstance`, no `vm` ni `vmi`.

• **El pedido no se crea, pero la comprobación de estado sigue devolviendo `200`.** No se creó la tabla:
  vuelve al mensaje sobre el esquema de la base de datos.

• **La máquina nueva (app-VM) se queda atascada en `Pending`.** No se apagó la máquina conversora:
  está reteniendo 8Gi de la cuota, y no queda suficiente para la nueva. Elimínala junto con su disco:
  ```bash
  kubectl delete vminstance convert --namespace tenant-workshopXX
  kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
  ```

• **`mc` reporta `Insufficient permissions` al subir la imagen.** En `convert.sh`, el campo
  `BUCKET` contiene `my-images` en lugar del `bucketName` real (el largo `bucket-...-...`).
  Toma el `bucketName` del Secret del bucket en el panel y colócalo ahí.

• **El disco se queda atascado en el estado Terminating.** Lo más probable es que el tamaño del disco sea menor que la imagen.
  Para ubuntu-20.04 necesitas al menos 25Gi.

• **Nada ayuda.** Escribe por aquí y lo resolvemos juntos. Esto es una parte normal del trabajo,
  no algo de lo que avergonzarse: en una migración real pasa lo mismo, solo que a las tres de la madrugada.
