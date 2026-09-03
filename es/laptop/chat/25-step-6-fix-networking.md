## 25. Paso 6: arreglar la red dentro de la máquina

**Primero la red, todo lo demás después**

📍 **Dónde:** dentro de tu máquina virtual, en la consola (no en la laptop).

📄 Este es el contenido de `scripts/netfix-dhcp.sh` del repositorio. **No hace falta descargarlo en la máquina, y tampoco podrías** — la máquina todavía no tiene red, y esa red faltante es justamente nuestra avería. Escribe los comandos a mano; son dos. El archivo vive en el repositorio para que puedas releerlo más tarde.

La aplicación está caída ahora mismo, y esto no es un fallo del entorno de pruebas. El pasado aún persiste dentro de la imagen: una dirección estática de la red de VMware y una pasarela que aquí no existe. La máquina se aferra a ellas y no ve ni el DNS del clúster ni a sus vecinos.

Entra en la máquina a través de la consola — desde la laptop:
```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```
🖱 **O con el ratón:** en el panel, abre tu máquina y haz clic en **VNC** — es la misma consola, solo que en el navegador. Ambos caminos pasan por la API del clúster y funcionan incluso ahora, cuando la red dentro de la máquina está rota.

A continuación — dentro de la máquina (esto es CentOS, la red se configura aquí, no en netplan):
```bash
sed -i 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/; /^IPADDR/d; /^GATEWAY/d; /^NETMASK/d; /^PREFIX/d; /^DNS/d' /etc/sysconfig/network-scripts/ifcfg-eth0
```
Comprueba con tus propios ojos qué quedó:
```bash
cat /etc/sysconfig/network-scripts/ifcfg-eth0
```
Debe quedar la línea `BOOTPROTO=dhcp`, y no debe haber líneas con una dirección ni con una pasarela. Si lo editas a mano con `nano`, el resultado es el mismo, solo que más lento.

Ahora hay que reiniciar la máquina:
```bash
reboot
```
🖱 **O con el ratón:** en el panel, en la página de la máquina, el botón **Restart**.

Después del reinicio, comprueba que la dirección se haya vuelto una del clúster:
```bash
ip -4 addr show eth0
```
Debería ser algo como `10.244.x.x`. Eso significa que la máquina está en la red del clúster y ve su DNS.

⚠️ El orden importa: mientras la dirección siga siendo la vieja, los nombres de los servicios no se resuelven, y no tiene sentido editar la configuración de la aplicación.
