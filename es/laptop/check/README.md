# Scripts de verificación

En cada carpeta de laboratorio hay un `check.sh`. Verifica que el laboratorio esté realmente hecho —
no que «se aplicó un archivo», sino que **funciona en lo esencial**.

Lo ejecutas tú mismo, cuando quieras. El resultado es un informe en la terminal y un archivo de artefacto
que puedes adjuntar donde quieras: el chat de la comunidad, una solicitud de certificación, tus propias
notas.

## Cómo ejecutarlo

```bash
cd labs/03-scale
./check.sh
```

### Si tienes Windows

Los scripts están escritos en bash y no se ejecutan en el propio Windows. Necesitas **WSL** — un subsistema
de Linux que se instala con un solo comando en un PowerShell de administrador:

```powershell
wsl --install
```

El equipo pedirá reiniciarse; después se abrirá una consola de Ubuntu. A partir de ahí todo es igual
que para los demás, solo que dentro de WSL necesitas tu propio `kubectl`:

```bash
sudo snap install kubectl --classic
```

Las credenciales para el clúster de laboratorio — ese mismo `lab.kubeconfig` que creaste en el laboratorio 0 —
las encuentra el script a través de la variable `KUBECONFIG`. Si lo guardaste dentro de WSL, la ruta
es la habitual:

```bash
export KUBECONFIG=~/lab.kubeconfig
```

Si lo guardaste en el disco de Windows, no hace falta copiarlo dentro de WSL — los discos son
visibles desde dentro en `/mnt/c/...`. Sustituye tu nombre de usuario de Windows y la carpeta donde
lo guardaste:

```bash
export KUBECONFIG=/mnt/c/Users/<tu-nombre>/lab.kubeconfig
```

⚠️ **Si no se puede instalar WSL** — una situación frecuente en una laptop corporativa — aún puedes
hacer los laboratorios por completo, todos excepto la verificación automática. En ese caso no obtendrás el
informe de artefacto: pide a un colega con Linux o macOS que ejecute el script contra tu kubeconfig, o
adjunta a tu solicitud la salida de comandos de la sección «Verificación» del laboratorio correspondiente.

El script averigua por sí solo dónde mirar, mediante la variable `KUBECONFIG`. Si no está
definida, te lo dice y se detiene.

Para los laboratorios que necesitan acceso a un tenant en el clúster de gestión, además necesitas la
variable `COZY_TENANT` — el nombre de tu tenant, por ejemplo `workshop07`:

```bash
export COZY_TENANT=workshop07
./check.sh
```

## Qué obtienes con ello

En la terminal — una línea por verificación:

```
[  OK  ] приложение развёрнуто и отвечает
[  OK  ] имя пода подставляется в страницу
[ FAIL ] автомасштабирование не настроено
         не найден HorizontalPodAutoscaler для deployment/rickroll
         подсказка: примените hpa.yaml из этой папки
```

⚠️ **El informe se escribe en la carpeta del laboratorio y lleva la fecha y la hora.** Si el
repositorio es compartido o has ejecutado la verificación varias veces, allí se acumularán varios archivos
— fíjate en la hora en el nombre para no confundir la ejecución de otra persona, o una anterior,
con la tuya.

Junto a él aparece un archivo `report-<lab>-<date>.md` — el mismo resultado en Markdown, junto
con las evidencias recogidas: versiones, salida de comandos, nombres de objetos. Ese es el artefacto.

## Requisitos para el autor del script

**Verifica lo esencial, no el hecho de la aplicación.** Mal: «existe un objeto Deployment». Bien:
«la aplicación responde por HTTP y en la respuesta está el nombre del Pod».

**Cada fallo explica qué hacer.** Una línea `FAIL` sin una pista es defectuosa. El lector
ejecuta el script precisamente porque está atascado.

**El script no arregla ni crea.** Solo lee. La única excepción es un Pod temporal
para probar la accesibilidad de red, que se limpia solo.

**Funciona en macOS y Linux.** Nada de `sed -i`, `readlink -f`, `date -d` específicos de GNU.
Probar en ambos sistemas.

**No se detiene en el primer error.** Ejecuta todas las verificaciones y muestra el panorama completo.
No usar `set -e`.

**No imprime contraseñas ni tokens.** Si un valor es secreto, escribe `<hidden>`.

**Idempotente.** Ejecutarlo diez veces seguidas no cambia el estado del clúster.

## Biblioteca compartida

`check/lib.sh` — funciones compartidas, incluidas al inicio de cada script:

- `ok "text"` / `fail "text" "hint"` / `warn "text"` — imprimir un resultado
- `need_kubeconfig` — verificar que `KUBECONFIG` esté definido y que el clúster responda
- `need_tenant` — verificar que `COZY_TENANT` esté definido
- `evidence "heading" "value"` — añadir una evidencia al artefacto
- `finish` — resumir, escribir el informe, devolver el código de salida

Código de salida: `0` — todo pasó, `1` — hay fallos. Así el script se puede usar
en automatización.
