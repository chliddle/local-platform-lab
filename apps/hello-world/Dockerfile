# syntax=docker/dockerfile:1

# Built with --platform=$BUILDPLATFORM and cross-compiled via GOOS/GOARCH so
# multi-arch builds (linux/amd64 + linux/arm64) compile natively on the
# runner instead of paying for QEMU emulation of the whole Go toolchain.
FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS builder

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

ARG VERSION=dev
ARG GIT_COMMIT_SHA=unknown
ARG TARGETOS
ARG TARGETARCH

RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build \
    -ldflags "-s -w \
      -X github.com/chliddle/local-platform/apps/hello-world/internal/buildinfo.Version=${VERSION} \
      -X github.com/chliddle/local-platform/apps/hello-world/internal/buildinfo.GitCommitSHA=${GIT_COMMIT_SHA}" \
    -o /out/hello-world .

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /out/hello-world /hello-world

EXPOSE 8080
USER nonroot:nonroot

ENTRYPOINT ["/hello-world"]
