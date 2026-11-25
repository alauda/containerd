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
#   tools           collect runc and nerdctl (downloaded and verified) and crictl only
#   cri-containerd  full package (default, last stage)

ARG REGISTRY=registry.alauda.io
ARG CONTAINERD_VERSION
ARG CRICTL_VERSION=1.33.0

FROM --platform=linux/amd64 ${REGISTRY}/acp/containerd:v${CONTAINERD_VERSION} AS containerd-amd64
FROM --platform=linux/arm64 ${REGISTRY}/acp/containerd:v${CONTAINERD_VERSION} AS containerd-arm64

FROM --platform=linux/amd64 ${REGISTRY}/migration-sink/ait/crictl:v${CRICTL_VERSION} AS crictl-amd64
FROM --platform=linux/arm64 ${REGISTRY}/migration-sink/ait/crictl:v${CRICTL_VERSION} AS crictl-arm64

FROM ${REGISTRY}/base-images/alpine:3 AS tools

# Checksums come from the upstream release assets:
#   runc     runc.sha256sum
#   nerdctl  SHA256SUMS
ARG RUNC_VERSION=1.3.7
ARG RUNC_SHA256_AMD64=3c8d24628a006cf52d8791cf8c4586f3a0cb7e29bed8ae4264aca3cb1edb972d
ARG RUNC_SHA256_ARM64=9edac6cba77b34d955bcdbf7001a1193f8964b255f0a7cf06ced3adf11f7cc00
ARG NERDCTL_VERSION=2.4.2
ARG NERDCTL_SHA256_AMD64=41a66995888043c0ba05f8061574eaba1b9e06b9b21c2a238215179df2728d3f
ARG NERDCTL_SHA256_ARM64=6bb9cfe435be3745c079cde6c1fd14d6515a84de2b285993d1d3e2be2c4fa36a

COPY --link --from=crictl-amd64 / /out/amd64/
COPY --link --from=crictl-arm64 / /out/arm64/

RUN apk add --no-cache wget

RUN set -eu; \
    for arch in amd64 arm64; do \
      case "${arch}" in \
        amd64) runc_sha="${RUNC_SHA256_AMD64}"; nerdctl_sha="${NERDCTL_SHA256_AMD64}" ;; \
        arm64) runc_sha="${RUNC_SHA256_ARM64}"; nerdctl_sha="${NERDCTL_SHA256_ARM64}" ;; \
      esac; \
      wget -q -O "/tmp/runc.${arch}" \
        "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.${arch}"; \
      echo "${runc_sha}  /tmp/runc.${arch}" | sha256sum -c -; \
      install -m 0755 "/tmp/runc.${arch}" "/out/${arch}/runc"; \
      rm -f "/tmp/runc.${arch}"; \
      wget -q -O "/tmp/nerdctl.${arch}.tar.gz" \
        "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/nerdctl-${NERDCTL_VERSION}-linux-${arch}.tar.gz"; \
      echo "${nerdctl_sha}  /tmp/nerdctl.${arch}.tar.gz" | sha256sum -c -; \
      tar -xzf "/tmp/nerdctl.${arch}.tar.gz" -C "/out/${arch}" nerdctl containerd-rootless.sh containerd-rootless-setuptool.sh; \
      rm -f "/tmp/nerdctl.${arch}.tar.gz"; \
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
