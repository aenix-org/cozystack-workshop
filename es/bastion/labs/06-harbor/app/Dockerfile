# Lab 6 · Tu propio registro privado de imágenes. Receta de construcción de la imagen del servicio «Pase de invitado».
#
# Qué es un Dockerfile: una receta paso a paso que convierte las fuentes en una imagen —
# una instantánea del sistema de archivos lista para ejecutar junto con las instrucciones de qué ejecutar dentro.
# Lo más parecido en vSphere es construir una plantilla dorada de VM, solo que descrita como texto y
# repetible: la misma receta produce el mismo resultado en cualquier máquina.
#
# Se construye en tu VM, desde la carpeta de la lab (el último argumento es la carpeta con este
# archivo y las fuentes):
#     docker build --platform linux/amd64 -t HARBOR-HOST/passes/passes-api:v1 app/
#     docker push HARBOR-HOST/passes/passes-api:v1
# Reemplaza HARBOR-HOST por la dirección de tu propio Harbor: la primera parte del nombre de la imagen es la
# dirección del registro, y así es como docker push sabe adónde enviarla.
#
# ATENCIÓN: --platform linux/amd64 es obligatorio en un Mac con procesador Apple Silicon y en cualquier
# VM ARM. Sin él obtienes una imagen ARM: se construye sin errores, se sube
# al registro sin errores, y luego en el clúster (cuyos nodos son x86) falla con «exec format error».
#
# Cada línea de la receta crea una capa — un corte inmutable del sistema de archivos. Las capas
# se cachean y se reutilizan: por eso los archivos se copian de uno en uno en lugar de la carpeta
# entera de golpe — editar main.go no obliga a volver a descargar las dependencias.
#
# DOS ETAPAS. La primera es la etapa de construcción: necesita el compilador de Go completo, unos 350 MB.
# La segunda es lo que se envía al clúster: solo se transfiere el binario terminado.
# La imagen resultante queda en torno a 10 MB en lugar de 350, y dentro no hay compilador,
# ni fuentes, ni gestor de paquetes — es decir, nada que pueda usar quien
# haya logrado entrar en el contenedor a pesar de todo.

# --- Etapa 1: construcción -----------------------------------------------------------------
# FROM — desde qué imagen ya hecha empezamos. Aquí es la imagen oficial con el compilador de Go
# sobre Alpine (un Linux mínimo, unos pocos megabytes). La versión está fijada: con la
# etiqueta latest la misma receta construiría algo distinto medio año después.
# AS build — el nombre de la etapa, por el cual la segunda etapa recogerá el resultado.
FROM golang:1.23-alpine AS build
# Carpeta de trabajo dentro de la imagen: los comandos siguientes se ejecutan en relación con ella.
# Si la carpeta no existe, se crea.
WORKDIR /src
# go.mod — la descripción del módulo: nombre y versión de Go. La aplicación no tiene dependencias externas,
# así que no hay nada que descargar de internet, y la construcción funciona donde no hay acceso saliente.
COPY go.mod ./
# La fuente en sí. Se copia en una línea aparte para que editar el código no invalide la caché
# de la capa anterior.
COPY main.go ./
# RUN ejecuta un comando en tiempo de construcción (no en tiempo de ejecución) y guarda el resultado como una capa.
#   CGO_ENABLED=0  construir estáticamente, sin enlazar con bibliotecas del sistema. Sin esto
#                  el binario necesitaría glibc, que no estará en la imagen final,
#                  y el contenedor fallaría al arrancar en lugar de al construir
#   -trimpath      eliminar del binario las rutas de la máquina de construcción: la construcción se vuelve
#                  reproducible, y el nombre de tu carpeta personal no se filtra
#   -ldflags="-s -w"  descartar las tablas de depuración — el archivo se vuelve notablemente más pequeño
#   -o /out/...    dónde poner el resultado; la segunda etapa lo recoge de ahí
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

# --- Etapa 2: lo que se envía al clúster -----------------------------------------------
# El segundo FROM empieza la imagen de nuevo, desde cero: todo lo acumulado en la primera etapa
# se queda allí y no llega a la imagen final.
FROM alpine:3.21
# Creamos el usuario con el que se ejecutará la aplicación: no debe ejecutarse como root.
# En un clúster bien configurado no se permitiría en absoluto que un pod se ejecute como root, y esto no es
# quisquillosidad sino un requisito de seguridad estándar.
#   -D          crear sin contraseña, sin hacer preguntas
#   -u 10001    identificador numérico; el clúster comprueba exactamente el número, no el nombre
RUN adduser -D -u 10001 app
# Lo único que se transfiere de la primera etapa es el binario terminado. --from=build
# apunta al nombre de la etapa. /usr/local/bin es una carpeta que existe en el PATH de cualquier Linux.
COPY --from=build /out/passes-api /usr/local/bin/passes-api
# A partir de este punto el proceso en el contenedor se ejecuta como el usuario 10001, no como root.
# El orden importa: las líneas de arriba se ejecutaron como root, de lo contrario adduser no habría funcionado.
USER 10001
# Declaración de puerto — una nota de referencia para personas y herramientas. No abre el puerto
# ni configura nada: el acceso a él se describe en el manifiesto (passes.yaml).
EXPOSE 8080
# Qué ejecutar al arrancar el contenedor. En forma de lista en lugar de cadena: así el comando
# se ejecuta directamente, sin una shell intermedia, y la señal de parada del clúster
# llega a la propia aplicación, no a la shell que la generó.
ENTRYPOINT ["/usr/local/bin/passes-api"]
