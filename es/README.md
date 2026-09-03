# Migración de VMware a Cozystack: taller y laboratorios

Materiales para quienes administran VMware y quieren entender qué es Cozystack,
no a partir de una presentación, sino con las manos. No hace falta saber Kubernetes: todo
se explica sobre la marcha, a través de lo que ya conoces de vSphere.

## Dos formas de hacerlo: elige la tuya

El mismo taller viene en dos variantes. Se diferencian únicamente en **desde dónde
trabajas con el clúster**. El instructor te dirá cuál es la tuya.

| | [`laptop/`](laptop/) — desde tu propia laptop | [`bastion/`](bastion/) — a través del bastion |
|---|---|---|
| **Herramientas** | las instalas tú: `kubectl`, `virtctl`, `kubelogin` | ya están instaladas en el bastion |
| **Acceso al clúster** | kubeconfig desde el panel, inicias sesión por el navegador | entras por SSH, el acceso ya está configurado |
| **Número de tenant en los archivos** | lo pones tú | ya puesto de antemano |
| **Comprobar la aplicación** | `virtctl port-forward` + `localhost:8080` | por nombre de dominio `app.<número>.workshop.aenix.io` |
| **Para quién** | quienes no tienen un bastion compartido | un entorno de pruebas preparado con bastion |

Dentro de cada carpeta hay un conjunto autosuficiente: su propio `README.md` (la ruta), `chat/`
(los mensajes de chat para cada paso), `manifests/`, `scripts/`. Abre el README de tu camino
y síguelo.

## Laboratorios

Ambas carpetas contienen `labs/`: dieciséis laboratorios independientes que haces
a tu propio ritmo, en casa o en los descansos. Cada uno viene con su propio script de comprobación
(`check/`). El conjunto completo son unas nueve horas, no para una sola sentada: haz uno por noche.

| Laboratorio | De qué trata | Tiempo |
|---|---|---|
| 0 · Tu propio clúster | consíguete un Kubernetes en diez minutos | 15 min |
| 1 · Primera aplicación | despliega una aplicación con un archivo y un comando | 25 min |
| 2 · Autoreparación | elimina una réplica y mira qué pasa | 25 min |
| 3 · Escalado | aplica carga y observa cómo crecen las réplicas | 30 min |
| 4 · Despliegue y reversión | cambia la versión bajo carga, sin interrupciones | 30 min |
| 5 · Infraestructura en Git | describe todo en un repositorio y publícalo con un push | 40 min |
| 6 · Tu propio registro | Harbor, compilar un servicio en Go, desplegar desde tu propio registro | 45 min |
| 7 · Caché | Redis delante de un backend lento, la ganancia en números | 50 min |
| 8 · Secretos | saca una contraseña del manifiesto y llévala a OpenBao | 50 min |
| 9 · Analítica | un millón de filas y un informe en milisegundos | 45 min |
| 10 · Documentos | MongoDB donde los registros tienen formas distintas | 45 min |
| 11 · Compilación móvil | compila un APK en el clúster, déjalo en un bucket | 40 min |
| 12 · Una VM al lado | los sistemas heredados no necesitan contenerizarse para migrar | 30 min |
| 13 · Lo tuyo en el catálogo | empaqueta una aplicación como app de Cozystack | 40 min |
| 14 · Observabilidad | encuentra en los gráficos los rastros de tu propia carga | 30 min |
| 15 · Qué hacer el lunes | por qué sistema empezar y qué prometerle a la dirección | 20 min |

Los enlaces a los laboratorios están en el README de tu camino: [`laptop/labs/`](laptop/labs/) o
[`bastion/labs/`](bastion/labs/).

## Administrativo

* [`CONVENTIONS.md`](CONVENTIONS.md) — cómo están escritos los materiales (para autores).
* [`REQUIREMENTS.md`](REQUIREMENTS.md) — qué hace falta para levantar el entorno de pruebas (para quienes
  preparan el taller: cuotas, el orden en que se crean los tenants, la versión de la plataforma).
