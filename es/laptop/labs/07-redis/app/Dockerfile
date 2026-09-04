# Lab 7 · receta de construcción de la imagen del servicio «Пропуск», versión v2.
#
# Un Dockerfile es una lista de pasos que convierten las fuentes en una imagen: una instantánea
# inmutable de un sistema de archivos junto con un comando de arranque. La analogía más familiar es
# una plantilla de máquina virtual, salvo que no se construye con el ratón sino con este mismo texto, vive
# en un registro y se versiona mediante una etiqueta.
#
# Se construye en el portátil, no en el clúster (véase el paso de construcción en el README):
#   docker build --platform linux/amd64 -t <ваш-harbor>/passes/passes-api:v2 app/
#   docker push  <ваш-harbor>/passes/passes-api:v2
#
# --platform linux/amd64 es obligatorio en un Mac con Apple Silicon: sin él la imagen se construirá
# para ARM, se subirá sin una sola queja y se caerá en el clúster con «exec format error».
#
# Una construcción en dos etapas.
#
# La primera etapa es la de construcción: necesita todo el compilador de Go, y eso son unos 350 MB.
# La segunda etapa es lo que irá al clúster: allí solo llega el binario terminado.
# Así la imagen final acaba en torno a los 10 MB en lugar de 350, y dentro de ella no hay ni
# compilador, ni fuentes, ni gestor de paquetes — es decir, no hay nada de lo que
# aprovecharse para quien sí logró entrar en el contenedor.

# FROM — de qué imagen preconstruida partimos. Aquí tomamos la imagen oficial con el compilador
# de Go basada en Alpine. AS build da a esta etapa un nombre para que la segunda etapa pueda sacar de ella
# el resultado. La versión está fijada (1.23), no latest: de lo contrario la construcción de mañana de la misma
# fuente puede producir un binario diferente.
FROM golang:1.23-alpine AS build
# WORKDIR — el directorio de trabajo dentro de la imagen. Todos los comandos siguientes se ejecutan en él.
WORKDIR /src
# COPY coloca archivos del portátil dentro de la imagen. En dos líneas, no en una: go.mod cambia
# rara vez, main.go — a menudo, y docker cachea cada paso por separado. Tocaste solo main.go —
# el paso de go.mod se toma de la caché.
COPY go.mod ./
COPY main.go ./
# RUN — ejecutar un comando justo durante la construcción; su resultado permanece en la imagen.
# CGO_ENABLED=0 — construir estáticamente, sin vincularse a las bibliotecas del sistema.
# Sin esto el binario requeriría glibc, que no estará en la imagen final.
# -trimpath elimina del binario las rutas de tu portátil, -ldflags="-s -w" descarta
# la información de depuración — la imagen es más pequeña, y los nombres de tus carpetas no se filtran al log.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

# El segundo FROM empieza la imagen de nuevo, desde cero. Todo lo que hubo en la etapa build
# se descarta en este punto, y en la imagen final solo llegará lo que copiemos explícitamente
# con el siguiente comando COPY --from=build.
FROM alpine:3.21
# La aplicación no se ejecuta como root. En un clúster correctamente configurado un pod que corre como root
# no será admitido en absoluto, y esto no es una nimiedad sino un requisito de seguridad estándar.
RUN adduser -D -u 10001 app
# Lo único que se traslada de la etapa de construcción es un solo archivo: el binario terminado.
COPY --from=build /out/passes-api /usr/local/bin/passes-api
# USER — con qué usuario ejecutar el proceso. Se da un número, no un nombre: kubernetes comprueba
# exactamente el número en el manifiesto (runAsNonRoot mira el uid), y deben coincidir.
USER 10001
# EXPOSE — una nota de que «este puerto se escucha dentro». No abre nada ni reenvía nada,
# esto es documentación para quien vaya a escribir el manifiesto.
EXPOSE 8080
# ENTRYPOINT — qué se ejecuta cuando arranca el contenedor. Aquí hay un único proceso y es
# el principal: cuando termina, termina el contenedor, y el clúster levanta una nueva copia.
ENTRYPOINT ["/usr/local/bin/passes-api"]
