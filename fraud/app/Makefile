BINS := switch terminals scorer cases dashboard
IMAGE ?= fraud-workshop:latest

.PHONY: build test image
build:
	@mkdir -p bin
	@set -e; for command in $(BINS); do CGO_ENABLED=0 go build -trimpath -o bin/$$command ./cmd/$$command; done

test:
	go vet ./...
	go test ./...

image:
	docker build -t $(IMAGE) .
