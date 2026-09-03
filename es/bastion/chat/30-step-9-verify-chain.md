## 30. Paso 9: verificamos toda la cadena

**El momento de la verdad**

⚠️ **Primero — dentro de la máquina virtual — apaga firewalld.** El CentOS migrado
arrastró reglas de su vida anterior y solo expone SSH hacia el exterior. El puerto de la
aplicación está cerrado, y desde afuera esto parecerá que «la aplicación no funciona».

```bash
systemctl stop firewalld
systemctl disable firewalld
```

Comprueba allí mismo, desde dentro de la máquina, que la aplicación está viva:

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
```

`200` — la aplicación responde. `503` — vuelve al paso de la red. Aquí `localhost` es la
propia máquina en la que estás sentado: la aplicación se está comprobando a sí misma.

📍 **A continuación — una comprobación desde afuera, por nombre de dominio.** En este camino
no hace falta reenvío de puertos: el instructor creó de antemano un `Ingress` en tu tenant, y
en cuanto la aplicación dentro de la máquina escucha en `8080`, la tienda queda publicada en
`https://app.workshopXX.workshop.aenix.io` (`XX` es tu número). Ábrela en el navegador de tu
laptop — o compruébala con `curl` directamente en el bastion:

```bash
# salud
curl -s https://app.workshopXX.workshop.aenix.io/actuator/health

# creamos un pedido
curl -s -X POST https://app.workshopXX.workshop.aenix.io/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

# vemos que quedó registrado
curl -s https://app.workshopXX.workshop.aenix.io/api/orders
```

⚠️ Mientras la app-VM no esté levantada o siga arrancando, el dominio responde `503` — esto
es normal: el `Ingress` está esperando al backend. En cuanto veas `200`, significa que la
máquina de adentro está escuchando en `8080`.

Si el pedido se creó — recorriste el camino completo. La aplicación llegó desde VMware,
corre en el clúster, escribe en una base de datos gestionada y envía eventos a una cola gestionada.

Hace media hora este sistema vivía en ESXi.
