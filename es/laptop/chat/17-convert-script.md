## 17. Una mirada de cerca: qué hay dentro de convert.sh

El script tiene cinco pasos, y cada uno imprime en qué está trabajando.

**Paso 1 — comprobación de la aceleración por hardware.** Busca el dispositivo `/dev/kvm`.
Internamente, `virt-v2v` levanta una pequeña máquina virtual para meterse dentro de la imagen — y si el
procesador se pasa hacia el interior de nuestra máquina, esta virtualización anidada va rápido. Si no
es así, se activa un modo por software: más lento, pero funciona. La línea
`LIBGUESTFS_BACKEND=direct` es justamente ese cambio hacia ese modo.

**Paso 2 — descarga de la imagen de origen.**

```bash
wget -O source.ova "$OVA_URL"
```

Descarga `app-1.ova` del almacenamiento compartido del taller — el mismo que aparece en el mapa de arriba. El
instructor subió allí el archivo con antelación. **En tu propio proyecto, aquí es donde iría una
exportación desde vSphere:** `Export OVF Template` u `ovftool`, y luego el mismo
reempaquetado.

**Paso 3 — el reempaquetado en sí.**

```bash
virt-v2v -i ova /root/source.ova -o local -os /root/out -of qcow2 -on app
```

`-i ova` — qué entra: un archivo en formato OVA. `-o local -os /root/out` — dónde poner el
resultado: en la carpeta local `/root/out`. `-of qcow2` — una opción **obligatoria**: sin ella
`virt-v2v` elegirá un formato por defecto, y la plataforma no aceptará ese disco. `-on app` —
cómo nombrar el resultado, y de ahí sale el nombre de archivo `app.qcow2`.

Esto tomará unos minutos — por la pantalla desfilarán líneas como `Copying disk 1/1`.
Aquí es exactamente donde ocurre ese segundo trabajo, invisible, con los controladores mencionados antes.

**Paso 4 — subida a tu bucket.**

```bash
mc alias set mybucket "$S3_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY"
mc cp /root/out/app.qcow2 "mybucket/$BUCKET/app.qcow2"
```

`mc alias set` recuerda la dirección del almacenamiento y las claves bajo el nombre corto `mybucket`, para que
después no tengas que repetirlas en cada comando. `mc cp` copia el archivo — la sintaxis es
deliberadamente la misma que la de un `cp` común.

**Paso 5 — un enlace para la plataforma.**

```bash
mc share download --expire 168h "mybucket/$BUCKET/app.qcow2"
```

Crea un enlace firmado temporal, válido por siete días (168 horas). Firmado — es decir, dentro de
la dirección va incrustada una firma criptográfica, y con este enlace cualquiera puede descargar el
archivo, pero solo con él y solo mientras siga vivo. No hace falta abrir el bucket al mundo
entero, ni tampoco hace falta entregarle tus claves de acceso a la plataforma.

Busca el enlace en la salida después de la palabra `Share:` — lo necesitarás en la siguiente fase.
