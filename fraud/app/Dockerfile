FROM golang:1.25 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN set -e; mkdir -p /out; for command in switch terminals scorer cases dashboard; do CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/$command ./cmd/$command; done

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/ /usr/local/bin/
ENTRYPOINT []
