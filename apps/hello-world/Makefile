.PHONY: build test run fmt vet

build:
	CGO_ENABLED=0 go build -o bin/hello-world .

test:
	go test ./...

fmt:
	gofmt -l .

vet:
	go vet ./...

run: build
	ENVIRONMENT=local ./bin/hello-world
