# Builds the static containerd binaries from this repository.
# Build context: repository root.
#
#   buildctl/docker build -f alauda/build/containerd.Dockerfile \
#     --build-arg VERSION=v2.2.10-acp.4 --build-arg REVISION=$(git rev-parse HEAD) .
#
# Output image (FROM scratch): containerd, containerd-shim-runc-v2,
# containerd-stress and ctr at the image root.

ARG REGISTRY=registry.alauda.io

FROM ${REGISTRY}/acp/builder-images/golang:1.26.11 AS builder

ARG GOPROXY=https://gomod.alauda.io,direct
ENV GOPROXY=${GOPROXY}
ENV GOSUMDB=off

# The btrfs snapshotter is compiled with cgo against the libbtrfs headers.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libbtrfs-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

# VERSION and REVISION are passed explicitly: the Makefile would otherwise
# derive them from git, which is not reliable inside the build container.
ARG VERSION
ARG REVISION
RUN test -n "${VERSION}" && test -n "${REVISION}" \
    && make STATIC=1 VERSION="${VERSION}" REVISION="${REVISION}" \
    && make STATIC=1 VERSION="${VERSION}" REVISION="${REVISION}" bin/containerd-shim-runc-v2

FROM scratch
COPY --from=builder /src/bin/* /
