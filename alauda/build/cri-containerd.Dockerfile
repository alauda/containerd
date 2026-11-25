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
#   tools           download and verify runc, nerdctl and crictl only
#   cri-containerd  full package (default, last stage)

ARG REGISTRY=registry.alauda.io
ARG CONTAINERD_VERSION

FROM --platform=linux/amd64 ${REGISTRY}/acp/containerd:v${CONTAINERD_VERSION} AS containerd-amd64
FROM --platform=linux/arm64 ${REGISTRY}/acp/containerd:v${CONTAINERD_VERSION} AS containerd-arm64

FROM ${REGISTRY}/base-images/alpine:3 AS tools

# Checksums come from the upstream release assets:
#   runc     runc.sha256sum
#   nerdctl  SHA256SUMS
#   crictl   crictl-v<version>-linux-<arch>.tar.gz.sha256
ARG RUNC_VERSION=1.5.3
ARG RUNC_SHA256_AMD64=50dcc0b257d724fe07f3852c2dda52340223f038227c7572644eec870741223e
ARG RUNC_SHA256_ARM64=07b52aee923cc432c38fe4fb6809a08fc6471994efed650af3635350588a20be
ARG NERDCTL_VERSION=2.4.2
ARG NERDCTL_SHA256_AMD64=41a66995888043c0ba05f8061574eaba1b9e06b9b21c2a238215179df2728d3f
ARG NERDCTL_SHA256_ARM64=6bb9cfe435be3745c079cde6c1fd14d6515a84de2b285993d1d3e2be2c4fa36a
ARG CRICTL_VERSION=1.36.0
ARG CRICTL_SHA256_AMD64=83855e114566a8a8c44c548d515670f51de3a5e1da8b2effb59870e2f10c25a3
ARG CRICTL_SHA256_ARM64=68328594ccf780a80ae2b092d9f6ce484eec7cf540c275242e8fd954bfd95332

RUN apk add --no-cache wget

RUN set -eu; \
    fetch() { wget -q -O "$1" "$2" && echo "$3  $1" | sha256sum -c -; }; \
    for arch in amd64 arm64; do \
      case "${arch}" in \
        amd64) runc_sha="${RUNC_SHA256_AMD64}"; nerdctl_sha="${NERDCTL_SHA256_AMD64}"; crictl_sha="${CRICTL_SHA256_AMD64}" ;; \
        arm64) runc_sha="${RUNC_SHA256_ARM64}"; nerdctl_sha="${NERDCTL_SHA256_ARM64}"; crictl_sha="${CRICTL_SHA256_ARM64}" ;; \
      esac; \
      out="/out/${arch}"; dl="/tmp/dl/${arch}"; \
      mkdir -p "${out}" "${dl}"; \
      fetch "${dl}/runc" \
        "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.${arch}" "${runc_sha}"; \
      install -m 0755 "${dl}/runc" "${out}/runc"; \
      fetch "${dl}/nerdctl.tar.gz" \
        "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/nerdctl-${NERDCTL_VERSION}-linux-${arch}.tar.gz" "${nerdctl_sha}"; \
      tar -xzf "${dl}/nerdctl.tar.gz" -C "${out}" nerdctl containerd-rootless.sh containerd-rootless-setuptool.sh; \
      fetch "${dl}/crictl.tar.gz" \
        "https://github.com/kubernetes-sigs/cri-tools/releases/download/v${CRICTL_VERSION}/crictl-v${CRICTL_VERSION}-linux-${arch}.tar.gz" "${crictl_sha}"; \
      tar -xzf "${dl}/crictl.tar.gz" -C "${out}" crictl; \
    done; \
    rm -rf /tmp/dl

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
