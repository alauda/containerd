# Packages the cri-containerd delivery image.
#
# The image carries, for both architectures regardless of the image platform:
#   /data/containerd-linux-amd64-<CONTAINERD_VERSION>.tar.gz
#   /data/containerd-linux-arm64-<CONTAINERD_VERSION>.tar.gz
# Each tarball holds the containerd binaries from acp/containerd:v<CONTAINERD_VERSION>,
# runc, nerdctl (with its rootless helper scripts), crictl and sha512.txt. Node
# installers verify the binaries against sha512.txt, so its name and the flat
# "./<file>" layout are part of the delivery contract.
#
# Targets:
#   tools           collect runc (downloaded and verified), nerdctl and crictl only
#   cri-containerd  full package (default, last stage)

ARG REGISTRY=registry.alauda.io
ARG CONTAINERD_VERSION
ARG NERDCTL_VERSION=2.1.2
ARG CRICTL_VERSION=1.33.0

FROM --platform=linux/amd64 ${REGISTRY}/acp/containerd:v${CONTAINERD_VERSION} AS containerd-amd64
FROM --platform=linux/arm64 ${REGISTRY}/acp/containerd:v${CONTAINERD_VERSION} AS containerd-arm64

FROM --platform=linux/amd64 ${REGISTRY}/migration-sink/ait/nerdctl:v${NERDCTL_VERSION} AS nerdctl-amd64
FROM --platform=linux/arm64 ${REGISTRY}/migration-sink/ait/nerdctl:v${NERDCTL_VERSION} AS nerdctl-arm64
FROM --platform=linux/amd64 ${REGISTRY}/migration-sink/ait/crictl:v${CRICTL_VERSION} AS crictl-amd64
FROM --platform=linux/arm64 ${REGISTRY}/migration-sink/ait/crictl:v${CRICTL_VERSION} AS crictl-arm64

FROM ${REGISTRY}/base-images/alpine:3 AS tools

# runc checksums come from the upstream release asset runc.sha256sum.
ARG RUNC_VERSION=1.2.8
ARG RUNC_SHA256_AMD64=09d2b25f31d3a819c97854c223ff9b36be7fdb0ce57fec709af499e1e19e8e89
ARG RUNC_SHA256_ARM64=7c463d49d83f2da9f5ba6db395600c8da6c5445fd4597c2de8e8b0f82eb1bebb

COPY --link --from=nerdctl-amd64 / /out/amd64/
COPY --link --from=nerdctl-arm64 / /out/arm64/
COPY --link --from=crictl-amd64 / /out/amd64/
COPY --link --from=crictl-arm64 / /out/arm64/

RUN apk add --no-cache wget

RUN set -eu; \
    for arch in amd64 arm64; do \
      case "${arch}" in \
        amd64) runc_sha="${RUNC_SHA256_AMD64}" ;; \
        arm64) runc_sha="${RUNC_SHA256_ARM64}" ;; \
      esac; \
      wget -q -O "/tmp/runc.${arch}" \
        "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.${arch}"; \
      echo "${runc_sha}  /tmp/runc.${arch}" | sha256sum -c -; \
      install -m 0755 "/tmp/runc.${arch}" "/out/${arch}/runc"; \
      rm -f "/tmp/runc.${arch}"; \
    done

FROM tools AS package

ARG CONTAINERD_VERSION

COPY --link --from=containerd-amd64 / /out/amd64/
COPY --link --from=containerd-arm64 / /out/arm64/

RUN set -eu; \
    test -n "${CONTAINERD_VERSION}"; \
    mkdir -p /data; \
    for arch in amd64 arm64; do \
      cd "/out/${arch}"; \
      chown -R 0:0 .; \
      chmod -R 0755 .; \
      for f in *; do if [ -f "${f}" ]; then sha512sum "${f}"; fi; done > /tmp/sha512.txt; \
      mv /tmp/sha512.txt sha512.txt; \
      tar -czf "/data/containerd-linux-${arch}-${CONTAINERD_VERSION}.tar.gz" -C "/out/${arch}" .; \
    done

FROM ${REGISTRY}/base-images/alpine:3.23.3-alauda-202611130220 AS cri-containerd

COPY --from=package /data /data
