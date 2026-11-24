# Alauda containerd

This repository carries the containerd builds shipped with Alauda Container
Platform: upstream containerd plus a small set of Alauda patches, and the
pipeline that packages them for node installation.

The primary repository is `code.alauda.io/acp/containerd`.
`github.com/alauda/containerd` is a read-only mirror.

## Branches

| Branch | Upstream series | Release tags | Manifest channel |
| --- | --- | --- | --- |
| `alauda/release-2.3` (default) | containerd 2.3 | `v2.3.<patch>-acp.<N>` | `main` |
| `alauda/release-2.2` | containerd 2.2 | `v2.2.<patch>-acp.<N>` | `release-2.2` |

- Each `alauda/release-*` branch is long-lived and carries its own `.tekton/`
  pipeline and `alauda/` packaging files.
- Alauda changes land through merge requests against the branch.
- Upstream patch releases are merged into the branch (`git merge v2.3.x`).
  History is never rewritten and the branches are never force-pushed.
- `main`, `release/*` and the upstream `v*` tags mirror upstream containerd.

## Releases

A release is a Git tag on the head of an `alauda/release-*` branch:

```
v<upstream version>-acp.<N>
```

`<N>` starts at 1 for each upstream version and increases with every release of
that version. A tag that has been pushed is never moved or reused.

Pushing the tag builds and publishes:

| Artifact | Example for `v2.3.7-acp.1` |
| --- | --- |
| `acp/containerd:v<version>` | `acp/containerd:v2.3.7-1` |
| `acp/cri-containerd:<version>` | `acp/cri-containerd:2.3.7-1` |
| Downstream manifest | component `cri-containerd`, channel per branch (table above) |

`acp/containerd` contains the static binaries `containerd`,
`containerd-shim-runc-v2`, `containerd-stress` and `ctr`.

`acp/cri-containerd` contains, for both architectures:

```
/data/containerd-linux-amd64-<version>.tar.gz
/data/containerd-linux-arm64-<version>.tar.gz
```

Each tarball holds the containerd binaries, `runc`, `nerdctl` with its rootless
helper scripts, `crictl`, and `sha512.txt` with the SHA-512 of every file.

The upstream version in the tag must match `version/version.go` on the tagged
commit; the pipeline rejects a mismatched tag.

To release:

```sh
git fetch origin
git tag -a v2.3.7-acp.1 -m "containerd v2.3.7-acp.1" origin/alauda/release-2.3
git push origin v2.3.7-acp.1
```

## Continuous integration

`.tekton/acp-containerd.yaml` runs on Pipelines as Code:

| Event | Result |
| --- | --- |
| Merge request to `alauda/release-*` | Build only: containerd for amd64, plus download and checksum verification of runc, nerdctl and crictl |
| Push to `alauda/release-*` | Same as a merge request |
| Push of a release tag | Build containerd for amd64 and arm64, push both images, publish the downstream manifest |

Non-release builds are versioned `<upstream version>-dev.<short commit>` and
push nothing.

## Following upstream

Fetch the new upstream tag, publish it to this repository, then merge it into
the branch through a merge request:

```sh
git remote add upstream https://github.com/containerd/containerd.git
git fetch --no-tags upstream tag v2.3.8
git push origin v2.3.8

git switch -c sync/v2.3.8 origin/alauda/release-2.3
git merge --no-ff v2.3.8
git push origin sync/v2.3.8
```

Resolve conflicts in favour of upstream except where an Alauda patch applies.
After the merge `version/version.go` reports the new upstream version, and the
next release tag uses it with `<N>` starting again at 1.

## Bundled tools

The runc, nerdctl and crictl versions, and the SHA-256 of each downloaded
artifact, are set in `alauda/build/cri-containerd.Dockerfile`. To update a
tool, change its version and both architecture checksums, taken from the
upstream release assets.

## Building locally

Build context is the repository root:

```sh
docker buildx build -f alauda/build/containerd.Dockerfile \
  --build-arg REGISTRY=registry.alauda.io \
  --build-arg VERSION=v2.3.7-dev.local \
  --build-arg REVISION="$(git rev-parse HEAD)" \
  --platform linux/arm64 -o type=local,dest=_output/containerd .
```

## Layout

```
.tekton/acp-containerd.yaml            pipeline
alauda/build/containerd.Dockerfile     static containerd build
alauda/build/cri-containerd.Dockerfile cri-containerd tarball packaging
alauda/README.md                       this document
```
