# Lab 7 · receta de construcción de la imagen del servicio «Pases», versión v2.
#
# Un Dockerfile es una lista de pasos por los que a partir del código fuente se obtiene una imagen:
# una instantánea inmutable del sistema de archivos junto con el comando de ejecución. El análogo
# más conocido que ya conoces es una plantilla de máquina virtual, pero no se construye con el ratón,
# sino con este texto, vive en un registro y se versiona mediante una etiqueta.
#
# Se construye en una VM, no en el clúster (véase el paso sobre la construcción en el README):
#   docker build --platform linux/amd64 -t <tu-harbor>/passes/passes-api:v2 app/
#   docker push  <tu-harbor>/passes/passes-api:v2
#
# --platform linux/amd64 es obligatorio en un Mac con Apple Silicon: sin él la imagen se construirá
# para ARM, se subirá sin una sola queja y caerá en el clúster con «exec format error».
#
# Construcción en dos etapas.
#
# La primera etapa es la de construcción: aquí se necesita todo el compilador de Go, que son unos 350 MB.
# La segunda etapa es lo que va al clúster: allí solo llega el binario ya compilado.
# Así la imagen final queda en unos 10 MB en lugar de 350, y dentro no hay ni
# compilador, ni fuentes, ni gestor de paquetes — es decir, no hay nada que pueda
# aprovechar quien logre entrar en el contenedor.

# FROM — desde qué imagen ya hecha empezamos. Aquí tomamos la imagen oficial con el compilador
# de Go basada en Alpine. AS build da un nombre a esta etapa para que en la segunda se pueda tomar
# de ella el resultado. La versión está fijada (1.23), no latest: de lo contrario la construcción
# de mañana del mismo código fuente puede dar un binario distinto.
FROM golang:1.23-alpine AS build
# WORKDIR — la carpeta de trabajo dentro de la imagen. Todos los comandos siguientes se ejecutan en ella.
WORKDIR /src
# COPY coloca archivos de la VM dentro de la imagen. En dos líneas, no una: go.mod cambia
# rara vez, main.go a menudo, y docker cachea cada paso por separado. Si tocas solo main.go —
# el paso de go.mod se tomará de la caché.
COPY go.mod ./
COPY main.go ./
# RUN — ejecutar un comando justo durante la construcción; su resultado queda en la imagen.
# CGO_ENABLED=0 — construir de forma estática, sin vínculos con las bibliotecas del sistema.
# Sin esto el binario requeriría glibc, que no estará en la imagen final.
# -trimpath elimina del binario las rutas de tu VM, -ldflags="-s -w" descarta
# la información de depuración — la imagen es más pequeña y en el log no se filtran los nombres de tus carpetas.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

# El segundo FROM empieza la imagen de nuevo, desde cero. Todo lo que había en la etapa build
# se descarta en este punto, y en la imagen final solo llegará lo que copiemos explícitamente
# con el siguiente comando COPY --from=build.
FROM alpine:3.21
# La aplicación no se ejecuta como root. En un clúster bien configurado un pod que corra como root
# no se permitirá en absoluto, y esto no es una nimiedad, sino un requisito de seguridad estándar.
RUN adduser -D -u 10001 app
# Lo único que se traslada de la etapa de construcción es un solo archivo: el binario ya compilado.
COPY --from=build /out/passes-api /usr/local/bin/passes-api
# USER — como quién ejecutar el proceso. Se indica un número, no un nombre: kubernetes comprueba
# en el manifiesto justamente el número (runAsNonRoot mira el uid), y deben coincidir.
USER 10001
# EXPOSE — una nota de que «dentro se escucha este puerto». No abre ni redirige nada,
# es documentación para quien vaya a escribir el manifiesto.
EXPOSE 8080
# ENTRYPOINT — lo que se ejecuta cuando arranca el contenedor. Aquí hay un solo proceso y es
# el principal: cuando termina, termina el contenedor, y el clúster levanta una copia nueva.
ENTRYPOINT ["/usr/local/bin/passes-api"]
