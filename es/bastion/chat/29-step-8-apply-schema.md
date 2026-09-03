## 29. Paso 8: instalamos el cliente y aplicamos el esquema

**Acceso a la base de datos:**
```
host:     postgres-db-rw.tenant-workshopXX.svc.cozy.local
database: orders
login:    orders
password: Orders2019!
```
La contraseña está definida en `manifests/04-managed.yaml`; no hace falta buscarla en ningún otro lado.

⚠️ **El psql que trae CentOS 7 no sirve.** Es la versión 9.2, y nuestra base de datos requiere
autenticación SCRAM, que no sabe manejar, así que responde:
`psql: SCRAM authentication requires libpq version 10 or above`. Necesitas un cliente de la versión 10 o más reciente.
Lo tomamos del repositorio PGDG — para CentOS 7 lo más nuevo disponible ahí es el 15.

Tres comandos seguidos, una razón para cada uno:

```bash
# 1. Conectamos el repositorio PGDG — la fuente de los paquetes de PostgreSQL.
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. La biblioteca libzstd, sin la cual el cliente no se instala. No está en los
#    repositorios de CentOS 7, así que la tomamos del archivo de EPEL.
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. El cliente en sí — solo desde el repositorio activo pgdg15.
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

El segundo y el tercer comando parecen redundantes, pero sin ellos la instalación falla, y de otro modo
verías ambos errores con tus propios ojos:

- sin `libzstd` — `Requires: libzstd >= 1.4.0`;
- sin `--disablerepo`/`--enablerepo` — `HTTPS Error 410 - Gone`. El paquete del repositorio
  incorpora de golpe todas las versiones de PostgreSQL, incluidas la 12 y la 13 ya sin soporte, y antes
  de instalar, `yum` recorre **cada** repositorio habilitado y falla en el primero que esté muerto.
  Nosotros dejamos explícitamente solo el que necesitamos.

Comprueba que el cliente está en su lugar:

```bash
psql --version
```

Si la respuesta es `command not found`, el cliente quedó fuera de tu `PATH`; encuéntralo y agrega
su directorio para la sesión actual:

```bash
ls /usr/pgsql-*/bin/psql
export PATH="$PATH:/usr/pgsql-15/bin"
psql --version
```

**Toma el archivo del esquema** — la máquina ya tiene red:

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/orders-schema.sql
```

**Lo aplicamos.** Desglosemos el comando parte por parte, para que no lo escribas a ciegas:

```bash
PGPASSWORD='Orders2019!' psql -h postgres-db-rw.tenant-workshopXX.svc.cozy.local \
  -U orders -d orders -f orders-schema.sql
```

- `PGPASSWORD='...'` — la contraseña se pasa por una variable de entorno, para que `psql` no
  la pida de forma interactiva. Así se hace en los scripts.
- `-h postgres-db-rw.tenant-workshopXX.svc.cozy.local` — la dirección de la base de datos. Esto **no es una IP**,
  sino un nombre interno dentro del clúster. El sufijo `-rw` importa: el Postgres gestionado tiene varias
  copias, y este nombre siempre apunta a aquella en la que **se puede escribir**. Existe un nombre emparejado con `-ro`
  — solo de lectura. Cuando los roles cambian entre las copias, el nombre no cambia, y por eso la
  configuración de la aplicación guarda este nombre y no la dirección de un servidor concreto.
- `-U orders` — con qué usuario conectarse, `-d orders` — a qué base de datos.
- `-f orders-schema.sql` — ejecutar los comandos del archivo.

Es precisamente la posibilidad de acceder a la base de datos por un nombre estable, y no por IP, lo que hace
que el cambio de copias sea invisible para la aplicación. En la máquina vieja tu configuración tenía
`localhost`, y ahí no había ningún cambio en absoluto.

Comprueba que la tabla está en su lugar:

```bash
PGPASSWORD='Orders2019!' psql -h postgres-db-rw.tenant-workshopXX.svc.cozy.local \
  -U orders -d orders -c '\dt'
```

Si aparece, entonces ahora sí se creará un pedido. Lo verificaremos en el siguiente paso, junto
con toda la cadena.
