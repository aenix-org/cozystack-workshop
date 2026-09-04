# Lab 7 · build recipe for the «Пропуск» service image, version v2.
#
# A Dockerfile is a list of steps that turn sources into an image: an immutable
# snapshot of a filesystem together with a startup command. The closest familiar analogy is
# a virtual machine template, except it is built not with a mouse but with this very text, it lives
# in a registry and is versioned by a tag.
#
# It is built on the laptop, not in the cluster (see the build step in the README):
#   docker build --platform linux/amd64 -t <ваш-harbor>/passes/passes-api:v2 app/
#   docker push  <ваш-harbor>/passes/passes-api:v2
#
# --platform linux/amd64 is mandatory on a Mac with Apple Silicon: without it the image will be built
# for ARM, will push without a single complaint, and will crash in the cluster with «exec format error».
#
# A two-stage build.
#
# The first stage is the build stage: it needs the whole Go compiler, and that is about 350 MB.
# The second stage is what will go to the cluster: only the finished binary lands there.
# This way the final image ends up around 10 MB instead of 350, and inside it there is neither
# a compiler, nor sources, nor a package manager — meaning there is nothing for
# whoever did get into the container to make use of.

# FROM — which prebuilt image we start from. Here we take the official image with the Go
# compiler based on Alpine. AS build gives this stage a name so that the second stage can take the
# result out of it. The version is pinned (1.23), not latest: otherwise tomorrow's build of the same
# source may produce a different binary.
FROM golang:1.23-alpine AS build
# WORKDIR — the working directory inside the image. All the following commands run in it.
WORKDIR /src
# COPY puts files from the laptop inside the image. In two lines, not one: go.mod changes
# rarely, main.go — often, and docker caches each step separately. Touched only main.go —
# the go.mod step is taken from the cache.
COPY go.mod ./
COPY main.go ./
# RUN — run a command right during the build; its result stays in the image.
# CGO_ENABLED=0 — build statically, without binding to system libraries.
# Without this the binary would require glibc, which won't be in the final image.
# -trimpath removes paths from your laptop out of the binary, -ldflags="-s -w" drops
# debug information — the image is smaller, and your folder names don't leak into the log.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

# The second FROM starts the image over, from a clean slate. Everything that was in the build stage
# is discarded at this point, and only what we explicitly copy with the next
# COPY --from=build command will land in the final image.
FROM alpine:3.21
# The application runs not as root. In a properly configured cluster a pod running as root
# won't be admitted at all, and this is not nitpicking but a standard security requirement.
RUN adduser -D -u 10001 app
# The only thing that moves over from the build stage is a single file: the finished binary.
COPY --from=build /out/passes-api /usr/local/bin/passes-api
# USER — which user to run the process as. A number is given, not a name: kubernetes checks
# exactly the number in the manifest (runAsNonRoot looks at the uid), and they must match.
USER 10001
# EXPOSE — a note that «this port is listened on inside». It opens nothing and forwards nothing,
# this is documentation for whoever will write the manifest.
EXPOSE 8080
# ENTRYPOINT — what runs when the container starts. There is a single process here and it is
# the main one: when it ends the container ends, and the cluster brings up a new copy.
ENTRYPOINT ["/usr/local/bin/passes-api"]
