## 27. Paso 7: cambiar la aplicación a los servicios gestionados

**Reemplazar las direcciones fijas por nombres**

📍 **Dónde:** dentro de tu máquina (app-VM), después del reinicio. No en el bastion.

📄 Este es el contenido de `scripts/connect-managed.sh`. Escríbelo a mano también — por la misma razón, y porque son solo tres comandos.

Dentro de la máquina, abre la configuración de la aplicación:
```bash
cat /etc/orders/application.properties
```
Verás esas mismas `192.168.10.30` y `192.168.10.40`. Este es el dolor de todo sistema heredado: ya nadie recuerda por qué precisamente estas direcciones.

Reemplázalas por los nombres de los servicios (sustituye `XX` por tu propio número):
```bash
sed -i 's|192.168.10.30|postgres-db-rw.tenant-workshopXX.svc.cozy.local|g' /etc/orders/application.properties
sed -i 's|192.168.10.40|kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local|g' /etc/orders/application.properties
systemctl restart orders-api
```
(dos comandos en lugar de uno con salto de línea: al copiar desde el chat el salto de línea suele perderse, y el comando termina ejecutándose solo a medias)

Compruébalo:
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```
`200` — la aplicación ve tanto la base de datos como la cola. Si obtienes `503`, vuelve al paso de red; lo más probable es que la dirección no haya cambiado.
