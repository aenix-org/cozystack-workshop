## 26. Primera comprobación: intentamos arrancarla y atrapamos el error

**No te saltes este paso. Es el más útil de todos.**

📍 **Dónde:** dentro de tu VM — la que levantaste en la tercera fase (app-VM). No en el bastion.

La VM migró, arrancó y la red funciona. Por toda lógica debería funcionar sin más — la aplicación está en esta VM exactamente donde siempre estuvo, no la tocamos. Comprobemos:

```bash
systemctl status orders-api
curl -s -o /dev/null -w 'HTTP %{http_code}\n' localhost:8080/actuator/health
```

**No funciona.** El servicio o no arrancó o responde con `503`. Veamos de qué se queja:

```bash
journalctl -u orders-api --no-pager | tail -20
```

El registro mostrará algo del estilo `Connection to 192.168.10.30:5432 refused`, o un tiempo de espera agotado contra esa misma dirección.

> **Detente y piensa antes de seguir leyendo.**
>
> No tocamos la aplicación, la VM arrancó, la red funciona. ¿Por qué no levanta?

<details>
<summary><b>La respuesta, y una lección más amplia que este error</b></summary>

Porque la configuración tiene las direcciones `192.168.10.30` y `192.168.10.40` clavadas a fuego — la base de datos y la cola, que vivían en **otras dos VMs en vSphere**. No las trajimos ni pensábamos hacerlo. Aquí no hay nada en esas direcciones.

La aplicación está bien, la VM está bien, la red está bien. Lo único que está roto es la suposición de que el mundo a su alrededor seguía siendo el mismo.

**Esto es lo que es una migración de verdad.** Mover un disco es la parte más fácil, y es la parte que normalmente se lleva toda la atención. Lo que se rompe es siempre lo que está afuera: direcciones, nombres DNS, credenciales, certificados, sistemas vecinos. Por eso en un proyecto real presupuestas un día para mover la VM y semanas para «hacerla funcionar».

Acabas de verlo por ti mismo en dos minutos y en carne propia, no en la presentación de otro.

</details>

**Qué hacemos a continuación.** No vamos a arreglar la aplicación sino su imagen del mundo: en lugar de las IP clavadas a fuego pondremos los nombres de los servicios gestionados que levantamos en el paso 5.
