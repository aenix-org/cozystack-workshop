## 30. Paso 9: verificamos toda la cadena

**El momento de la verdad**

⚠️ **Primero — dentro de la máquina virtual — apaga firewalld.** El CentOS migrado
arrastró reglas de su vida anterior y solo expone SSH hacia el exterior. El puerto de la
aplicación está cerrado, y un reenvío de puertos desde tu laptop chocará con `no route to host`
— y esto parecerá que «la aplicación no funciona».

```bash
systemctl stop firewalld
systemctl disable firewalld
```

Comprueba allí mismo, desde dentro de la máquina, que la aplicación está viva:

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
```

`200` — puedes hacer reenvío de puertos. `503` — vuelve al paso de la red.

📍 **A continuación — en tu laptop.** Reenvía hacia ti el puerto de la aplicación:
```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```
No cierres la ventana con este comando: el túnel vive mientras siga corriendo.

⚠️ **Aquí `vmi/` es obligatorio, mientras que en `virtctl console` es al revés — estorba.** Esto
no es una errata ni un capricho nuestro: los dos comandos tienen una sintaxis de destino distinta.
`port-forward` exige `tipo/nombre` y sin el prefijo responde `target must contain type and name
separated by '/'`. `console` espera solo el nombre y con el prefijo responde `forbidden`, porque
toma la palabra `vmi` por el nombre de la máquina.

Si virtctl se queja de una diferencia de versiones entre el cliente y el clúster — es una
advertencia, no un error, y no estorba.

Si el reenvío aun así no se levanta, el mismo túnel se puede hacer a través del Pod de la máquina:
```bash
kubectl get pod -n tenant-workshopXX -l vm.kubevirt.io/name=vm-instance-app-1
kubectl port-forward -n tenant-workshopXX <nombre-del-pod-del-resultado> 8080:8080
```

En otra ventana de terminal:
```bash
# salud
curl -s http://localhost:8080/actuator/health

# creamos un pedido
curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

# vemos que quedó registrado
curl -s http://localhost:8080/api/orders
```

Si el pedido se creó — recorriste el camino completo. La aplicación llegó desde VMware,
corre en el clúster, escribe en una base de datos gestionada y envía eventos a una cola gestionada.

Hace media hora este sistema vivía en ESXi.
