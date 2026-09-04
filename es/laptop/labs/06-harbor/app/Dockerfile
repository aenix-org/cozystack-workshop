# Lab 6 · Tu propio registro privado de imágenes. Receta de construcción de la imagen del servicio «Пропуск».
#
# Qué es un Dockerfile: una receta paso a paso que, a partir del código fuente, produce una imagen —
# una instantánea lista para ejecutar del sistema de archivos junto con la indicación de qué arrancar dentro.
# Lo más parecido en vSphere es construir una plantilla dorada de VM, solo que descrita como texto y
# repetible: la misma receta da el mismo resultado en cualquier máquina.
#
# Se construye en tu portátil, desde la carpeta de la lab (el último argumento es la carpeta con este
# archivo y el código fuente):
#     docker build --platform linux/amd64 -t HARBOR-HOST/passes/passes-api:v1 app/
#     docker push HARBOR-HOST/passes/passes-api:v1
# Reemplaza HARBOR-HOST por la dirección de tu propio Harbor: la primera parte del nombre de la imagen es la
# dirección del registro, y por ella docker push sabe adónde enviarla.
#
# ATENCIÓN: --platform linux/amd64 es obligatorio en un Mac con procesador Apple Silicon y en cualquier
# portátil ARM. Sin él obtendrás una imagen para ARM: se construye sin errores, se envía
# al registro sin errores, y luego en el clúster (cuyos nodos son x86) se cae con «exec format error».
#
# Cada línea de la receta crea una capa — un corte inmutable del sistema de archivos. Las capas se
# cachean y se reutilizan: por eso los archivos se copian uno a uno y no la carpeta
# entera de golpe — editar main.go no obliga a volver a descargar las dependencias.
#
# DOS ETAPAS. La primera es la de construcción: aquí hace falta todo el compilador de Go, que son unos 350 MB.
# La segunda es lo que viaja al clúster: allí solo se traslada el binario terminado.
# La imagen resultante queda en torno a 10 MB en lugar de 350, y dentro no hay ni compilador,
# ni código fuente, ni gestor de paquetes — es decir, nada de lo que echar mano para quien
# sí consiga entrar en el contenedor.

# --- Etapa 1: construcción -----------------------------------------------------------------
# FROM — desde qué imagen ya hecha empezamos. Aquí es la imagen oficial con el compilador de Go
# sobre Alpine (un Linux mínimo, unos pocos megabytes). La versión está fijada: con la etiqueta
# latest la misma receta construiría algo distinto medio año después.
# AS build — el nombre de la etapa; por él la segunda etapa recogerá el resultado.
FROM golang:1.23-alpine AS build
# Carpeta de trabajo dentro de la imagen: los comandos siguientes se ejecutan relativos a ella.
# Si la carpeta no existe, se crea.
WORKDIR /src
# go.mod — la descripción del módulo: su nombre y la versión de Go. La aplicación no tiene dependencias
# externas, así que no hay nada que descargar de internet, y la construcción funciona donde no hay salida al exterior.
COPY go.mod ./
# El código fuente en sí. Se copia en una línea aparte para que editar el código no invalide la caché
# de la capa anterior.
COPY main.go ./
# RUN ejecuta un comando durante la construcción (no en la ejecución) y guarda el resultado como una capa.
#   CGO_ENABLED=0  construir de forma estática, sin atarse a bibliotecas del sistema. Sin esto
#                  el binario necesitaría glibc, que no estará presente en la imagen final,
#                  y el contenedor se caería al arrancar en lugar de al construir
#   -trimpath      eliminar del binario las rutas de la máquina de construcción: la construcción se vuelve
#                  reproducible, y hacia fuera no se filtra el nombre de tu carpeta personal
#   -ldflags="-s -w"  descartar las tablas de depuración — el archivo queda notablemente más pequeño
#   -o /out/...    dónde poner el resultado; desde aquí lo recoge la segunda etapa
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

# --- Etapa 2: lo que viaja al clúster -----------------------------------------------
# El segundo FROM empieza la imagen de nuevo, desde cero: todo lo acumulado en la primera etapa
# se queda allí y no llega a la imagen final.
FROM alpine:3.21
# Damos de alta al usuario bajo el que funcionará la aplicación: no debe funcionar como root.
# En un clúster bien configurado un pod que corre como root no se admitirá en absoluto, y esto no es
# quisquillosidad sino un requisito de seguridad estándar.
#   -D          crear sin contraseña, sin hacer preguntas
#   -u 10001    identificador numérico; el clúster comprueba precisamente el número, no el nombre
RUN adduser -D -u 10001 app
# Lo único que se traslada de la primera etapa es el binario terminado. --from=build
# apunta al nombre de la etapa. /usr/local/bin es una carpeta que existe en el PATH de cualquier Linux.
COPY --from=build /out/passes-api /usr/local/bin/passes-api
# A partir de este punto el proceso en el contenedor funciona bajo el usuario 10001, y no bajo root.
# El orden importa: las líneas de arriba se ejecutaron como root, de lo contrario adduser no habría funcionado.
USER 10001
# La declaración del puerto — una anotación informativa para las personas y las herramientas. No abre el
# puerto ni configura nada: el acceso a él se describe en el manifiesto (passes.yaml).
EXPOSE 8080
# Qué arrancar al iniciar el contenedor. En forma de lista y no de cadena: así el comando
# se ejecuta directamente, sin una shell intermedia, y la señal de parada del clúster
# llega hasta la propia aplicación y no hasta la shell que la engendró.
ENTRYPOINT ["/usr/local/bin/passes-api"]
