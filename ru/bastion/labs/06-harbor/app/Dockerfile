# Lab 6 · Your own private image registry. Build recipe for the «Guest Pass» service image.
#
# What a Dockerfile is: a step-by-step recipe that turns sources into an image —
# a ready-to-run filesystem snapshot together with instructions on what to run inside it.
# The closest thing in vSphere is building a golden VM template, only described as text and
# repeatable: the same recipe yields the same result on any machine.
#
# Built on your VM, from the lab folder (the last argument is the folder with this
# file and the sources):
#     docker build --platform linux/amd64 -t HARBOR-HOST/passes/passes-api:v1 app/
#     docker push HARBOR-HOST/passes/passes-api:v1
# Replace HARBOR-HOST with the address of your own Harbor: the first part of the image name is the
# registry address, and that is how docker push knows where to send it.
#
# ATTENTION: --platform linux/amd64 is mandatory on a Mac with an Apple Silicon processor and on any
# ARM VM. Without it you get an ARM image: it builds without errors, pushes to
# the registry without errors, and then in the cluster (whose nodes are x86) fails with "exec format error".
#
# Each line of the recipe creates a layer — an immutable slice of the filesystem. Layers
# are cached and reused: that is why files are copied one at a time rather than the whole
# folder at once — editing main.go does not force re-downloading the dependencies.
#
# TWO STAGES. The first is the build stage: it needs the entire Go compiler, about 350 MB.
# The second is what ships to the cluster: only the finished binary is carried over.
# The resulting image ends up around 10 MB instead of 350, and inside it there is no compiler,
# no sources, and no package manager — that is, nothing to use for anyone who does
# get into the container after all.

# --- Stage 1: build -----------------------------------------------------------------
# FROM — which ready-made image we start from. Here it is the official image with the Go compiler
# on top of Alpine (a minimal Linux, a few megabytes). The version is pinned: with the
# latest tag the same recipe would build something different half a year later.
# AS build — the stage name, by which the second stage will pick up the result.
FROM golang:1.23-alpine AS build
# Working folder inside the image: subsequent commands run relative to it.
# If the folder does not exist, it is created.
WORKDIR /src
# go.mod — the module description: name and Go version. The application has no external dependencies,
# so there is nothing to download from the internet, and the build works where there is no outbound access.
COPY go.mod ./
# The source itself. Copied on a separate line so that editing the code does not invalidate the cache
# of the previous layer.
COPY main.go ./
# RUN executes a command at build time (not at run time) and saves the result as a layer.
#   CGO_ENABLED=0  build statically, without binding to system libraries. Without this
#                  the binary would need glibc, which will not be in the final image,
#                  and the container would fail at startup rather than at build time
#   -trimpath      strip build-machine paths from the binary: the build becomes
#                  reproducible, and the name of your home folder does not leak out
#   -ldflags="-s -w"  drop the debug tables — the file becomes noticeably smaller
#   -o /out/...    where to put the result; the second stage picks it up from there
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

# --- Stage 2: what ships to the cluster -----------------------------------------------
# The second FROM starts the image over, from a clean slate: everything built up in the first stage
# stays there and does not make it into the final image.
FROM alpine:3.21
# Create the user the application will run as: it must not run as root.
# In a properly configured cluster a pod would not be allowed to run as root at all, and this is not
# nitpicking but a standard security requirement.
#   -D          create without a password, asking no questions
#   -u 10001    numeric identifier; the cluster checks exactly the number, not the name
RUN adduser -D -u 10001 app
# The only thing carried over from the first stage is the finished binary. --from=build
# points to the stage name. /usr/local/bin is a folder that exists in the PATH of any Linux.
COPY --from=build /out/passes-api /usr/local/bin/passes-api
# From this point on the process in the container runs as user 10001, not as root.
# Order matters: the lines above ran as root, otherwise adduser would not have worked.
USER 10001
# Port declaration — a reference note for humans and tools. It does not open the port
# and configures nothing: access to it is described in the manifest (passes.yaml).
EXPOSE 8080
# What to run when the container starts. In list form rather than a string: this way the command
# is run directly, without an intermediate shell, and the stop signal from the cluster
# reaches the application itself, not the shell that spawned it.
ENTRYPOINT ["/usr/local/bin/passes-api"]
