# qbittorrent

A container image of qBittorrent, built from source: **qBittorrent 5.3.0** on
**libtorrent 1.2.20**, statically linked against musl.

It is built in two compiled libtorrent profiles — **`base`** (safe on the
smallest box) and **`10g`** (tuned for a 10 Gbit seedbox) — across two
targets: **amd64** (baseline `x86-64-v2` or `znver3`) and **arm64**
(`aarch64`, cross-compiled). The allocator is a further axis: **`musl`**
(musl's own malloc — the default) and, for the `10g-znver3` amd64 line only,
**`mimalloc`** (mimalloc v3.5.4 statically linked as a drop-in replacement).

It is a drop-in replacement for a `qbittorrent-nox` container: same binary
name, same `/config` layout, same environment variables, and it runs unprivileged
with a read-only root filesystem.

## Tags

| tag | meaning |
|---|---|
| `5.3.0-lt1.2.20` | moving tag, `base` profile, multi-arch manifest (amd64 + arm64) |
| `5.3.0-lt1.2.20-10g` | moving tag, `10g` profile, baseline CPU, multi-arch manifest (amd64 + arm64) |
| `5.3.0-lt1.2.20-10g-znver3` | moving tag, `10g` profile, `znver3` amd64, `musl` |
| `5.3.0-lt1.2.20-10g-znver3-mimalloc` | moving tag, `10g` profile, `znver3` amd64, `mimalloc` |
| `sha-<12 hex>` | immutable tag for the commit (`10g-znver3` musl) |
| `sha-<12 hex>-mimalloc` | immutable tag for the commit (`10g-znver3` mimalloc) |
| `sha-<12 hex>-base` | immutable multi-arch manifest for the commit (`base`) |
| `sha-<12 hex>-10g` | immutable multi-arch manifest for the commit (`10g` baseline) |

The multi-arch tags are assembled from per-arch images that are also pushed, as
`<tag>-amd64` and `<tag>-arm64`; those are build artefacts the manifest is made
from, not intended for pinning.

## CPU requirement

- `5.3.0-lt1.2.20-10g-znver3[-mimalloc]`: compiled with `-march=znver3
  -mtune=znver3` — AMD Zen 3 (Ryzen 5000, EPYC 7003) or newer (AVX2, BMI2, FMA,
  VAES, …). **On anything older the binary will die with SIGILL.**
- `5.3.0-lt1.2.20` and `5.3.0-lt1.2.20-10g` (amd64): compiled with
  `-march=x86-64-v2` (SSE4.2, POPCNT, …), the baseline that runs on any
  x86-64 CPU from ~2009 on.
- `5.3.0-lt1.2.20` and `5.3.0-lt1.2.20-10g` (arm64): compiled for the
  `armv8-a` baseline (any 64-bit ARM server).

`verify-binary.sh` asserts the exact architecture and `-march` of every build:
the ELF machine, the recorded `.GCC.command.line` flags, and — for amd64 — an
instruction census (BMI2/AVX present in a `znver3` build, absent from an
`x86-64-v2` build).

## The build matrix

| profile | CPU | arch | allocator | tag |
|---|---|---|---|---|
| base | baseline | amd64 | musl | `5.3.0-lt1.2.20` |
| base | baseline | arm64 | musl | `5.3.0-lt1.2.20` |
| 10g | baseline | amd64 | musl | `5.3.0-lt1.2.20-10g` |
| 10g | baseline | arm64 | musl | `5.3.0-lt1.2.20-10g` |
| 10g | znver3 | amd64 | musl | `5.3.0-lt1.2.20-10g-znver3` |
| 10g | znver3 | amd64 | mimalloc | `5.3.0-lt1.2.20-10g-znver3-mimalloc` |

`base` and `10g` differ only in two compile-only libtorrent defaults
(`send_not_sent_low_watermark` and `max_peer_recv_buffer_size`); four other
tunings are shared. The runtime profiles (`light`/`1g`/`10g`) are
`qBittorrent.conf` presets, not image axes — they are not built as tags. See
[patches/libtorrent/README.md](patches/libtorrent/README.md).

## Runtime contract

```sh
docker run -d \
  --name qbittorrent \
  --read-only --tmpfs /tmp \
  --user 65534:65534 \
  -v /srv/qbittorrent:/config \
  -e QBT_WEBUI_PORT=8080 \
  -e QBT_TORRENTING_PORT=51413 \
  -p 8080:8080 -p 51413:51413 -p 51413:51413/udp \
  ghcr.io/swizzin/qbittorrent:5.3.0-lt1.2.20
```

| item | value |
|---|---|
| binary | `/app/qbittorrent-nox` (root-owned, 0755) |
| config | `/config/qBittorrent/qBittorrent.conf` |
| `HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME` | `/config` |
| user | `65534:65534` |
| workdir / volume | `/config` |
| exposed port | `8080` |
| entrypoint | `/usr/bin/catatonit -- /entrypoint.sh` |

`QBT_CONFIRM_LEGAL_NOTICE=1` is set so a fresh container starts without the
interactive legal notice.

Ports are **not** baked into the image: qBittorrent reads `QBT_WEBUI_PORT` and
`QBT_TORRENTING_PORT` (any command-line option `--foo-bar` has an environment
variable `QBT_FOO_BAR`) and the entrypoint does not override them.

The entrypoint only prepares `/config/qBittorrent`: it creates `logs/`, points
`logs/qbittorrent.log` at the container's stdout if that path is free, removes a
lockfile left behind by a killed container, then `exec`s the binary. No
`qBittorrent.conf` is baked into the image and no authentication bypass
(`AuthSubnetWhitelist`, `LocalHostAuth=false`) is configured — provisioning the
first-run configuration is the deploying tool's job.

Because the binary is static, the image needs no libc, no Python and no shell
tooling at runtime; with `/config` and `/tmp` writable it runs with
`--read-only` and any non-root uid.

## What is in the image

- `qbittorrent-nox` 5.3.0, static, stripped
- `unrar` 7.23 (from `ghcr.io/linuxserver/unrar`, Alpine build)
- `7zz` 26.01 (Alpine `7zip` package, `7z` is a symlink)
- `unzip` (busybox applet)
- `qbt-unpack` at `/usr/local/bin/qbt-unpack` — post-download archive
  extraction, meant for *Options → Downloads → Run external program on torrent
  completion*: `/usr/local/bin/qbt-unpack "%F"`
- `bash`, `catatonit`, `tzdata`, `ca-certificates`

`/app/BUILD-INFO` records the exact versions, the CPU target, the profile, the
architecture, the allocator, the sha256 of the build script and the sha256 of
the patch the image was built with.

## Patches

- `patches/libtorrent/1.2.20/patch` — the `10g` profile: six compiled-in
  libtorrent defaults.
- `patches/libtorrent/1.2.20/base.patch` — the `base` profile: the same six,
  except `send_not_sent_low_watermark` and `max_peer_recv_buffer_size` stay at
  the stock/baseline values.

See [patches/libtorrent/README.md](patches/libtorrent/README.md) for what each
one does and why, and the two values that differ between the profiles.

qBittorrent itself is built from the `release-5.3.0` tag **unpatched**. The
build script would otherwise fetch patches for the tag from
userdocs/qbittorrent-nox-static at build time; the Dockerfile puts a
comment-only file in that module's patch directory, which makes the script take
its local (empty) patch path instead. The build asserts that exactly one patch
was applied and that the qBittorrent tree is still the pristine tag.

## Allocator variants

`ARG ALLOCATOR` selects the memory allocator; for the `10g-znver3` amd64 line it
is the **only** difference between two images.

- `ALLOCATOR=musl` (default): musl's own malloc. This is the build the `musl`
  tag has always carried.
- `ALLOCATOR=mimalloc`: [mimalloc](https://github.com/microsoft/mimalloc)
  **v3.5.4**, compiled to a single object file (`MI_BUILD_OBJECT`) with
  `MI_OVERRIDE=ON` and `MI_LIBC_MUSL=ON`, and linked **first** on the final
  link line through `LDFLAGS`. Because the linker only pulls musl's
  `malloc.o`/`free.o`/… out of `libc.a` to satisfy an undefined symbol, and
  mimalloc's object is linked before `libc.a`, mimalloc replaces
  `malloc`/`free`/`calloc`/`realloc`/`aligned_alloc`/`posix_memalign`/
  `memalign`/`malloc_usable_size` cleanly — no `-z muldefs`. `MI_SECURE=OFF`,
  no debug, Release; no `MIMALLOC_*` environment variables are set at runtime,
  so mimalloc runs at its default behaviour.

  mimalloc is pinned to **v3.5.4** deliberately: v3.6.0 added an always-on
  profiler, which would contaminate the comparison. The release tarball is
  pinned by sha256 (`MIMALLOC_TAG` + `MIMALLOC_SHA256` in the Dockerfile), and
  the object is compiled with the same `-march=znver3 -mtune=znver3
  -frecord-gcc-switches` flags as everything else.

`mimalloc` is only valid for the `10g-znver3` amd64 line; the Dockerfile fails
any other combination, and the baseline/arm64 images are `musl` only. Any other
`ALLOCATOR` value fails the build. A third allocator (e.g. jemalloc) would be
added the same way: a pin for its source, a build step that produces a
linkable object, a `-suffix` for its tag in `hack/versions.sh`, and an
allocator branch in `hack/verify-binary.sh`.

`/app/BUILD-INFO` records `allocator=musl|mimalloc`, plus `mimalloc_tag` and
`mimalloc_sha256` for the mimalloc variant.

## Updating

qBittorrent: change `QBT_VERSION` at the top of the Dockerfile (for example
`5.3.1`) and push. That is the whole change. The image tag, the OCI labels,
`BUILD-INFO` and both check scripts read the version from the Dockerfile through
`hack/versions.sh`, and there are no per-version qBittorrent patch files.

libtorrent: change `LT_VERSION`, then regenerate
`patches/libtorrent/<version>/patch` and `base.patch` from that tag's
`src/settings_pack.cpp` (see [patches/libtorrent/README.md](patches/libtorrent/README.md))
and check they apply. OpenSSL: change `OPENSSL_TAG`. mimalloc: change
`MIMALLOC_TAG` and `MIMALLOC_SHA256` together (stay on a 3.5.x with no
always-on profiler). Qt and Boost are chosen by the pinned build script; moving
to a newer build script means updating its commit and sha256 together.

## Building locally

Requirements: docker with buildx, ~20 GiB of free disk. The amd64 builds run
natively; the arm64 builds are cross-compiled but need qemu binfmt to assemble
the arm64 runtime image and smoke-test it.

```sh
# base profile, baseline amd64
docker buildx build --load --platform linux/amd64 \
  --build-arg PROFILE=base --build-arg MARCH=x86-64-v2 \
  -t qbittorrent:5.3.0-lt1.2.20 .

# 10g profile, baseline amd64
docker buildx build --load --platform linux/amd64 \
  --build-arg PROFILE=10g --build-arg MARCH=x86-64-v2 \
  -t qbittorrent:5.3.0-lt1.2.20-10g .

# 10g profile, znver3 amd64 (the existing line), and its mimalloc A/B partner
docker buildx build --load --platform linux/amd64 \
  -t qbittorrent:5.3.0-lt1.2.20-10g-znver3 .
docker buildx build --load --platform linux/amd64 \
  --build-arg ALLOCATOR=mimalloc \
  -t qbittorrent:5.3.0-lt1.2.20-10g-znver3-mimalloc .

# arm64 (cross-compiled; qemu binfmt must be registered for the runtime stage)
docker buildx build --load --platform linux/arm64 \
  --build-arg PROFILE=base \
  -t qbittorrent:5.3.0-lt1.2.20-arm64 .
```

The build is done by [userdocs/qbittorrent-nox-static](https://github.com/userdocs/qbittorrent-nox-static)
pinned to commit `66a0aa3fd2044dcd2a327670aba35779b0957e34`, and the script
itself is pinned by sha256 in the `ADD --checksum` line. Everything else is
pinned too: qBittorrent `release-5.3.0`, libtorrent `v1.2.20`, OpenSSL
`openssl-3.5.9` (the 3.5 LTS line: libtorrent 1.2 pulls Boost 1.86, whose asio
TLS hostname verification does not compile against the opaque `ASN1_STRING` of
OpenSSL 4.x), libiconv 1.18 by sha256, and Alpine 3.24 by digest (a multi-arch
index, so the same pin resolves amd64 and arm64). Patches are copied into the
script's patch tree before the build, so the compile step needs no network
access for patches.

About 10–15 minutes on a 24-thread Zen 3 host. `--build-arg BUILD_JOBS=`
controls parallelism; the default is 16 to stay inside 32 GiB of RAM.

The Dockerfile fails the build if the libtorrent patch did not apply, if the
qBittorrent tree was patched, if the patched source is not the source that was
compiled, or if the compiler was not invoked with the target `-march`. Patch
application is not otherwise fatal in the upstream script, so this check is the
real gate.

## Verifying

```sh
hack/verify-binary.sh qbittorrent:5.3.0-lt1.2.20
hack/smoke.sh        qbittorrent:5.3.0-lt1.2.20
```

`verify-binary.sh` inspects the stripped binary: qBittorrent and libtorrent
version strings, absence of gcov/profiling/tcmalloc artefacts, static linkage,
the recorded compiler flags (`.GCC.command.line`, written by
`-frecord-gcc-switches` and preserved through `-s` and LTO), the ELF machine
(asserts amd64 vs arm64 against the build's `arch`), and an instruction census:
BMI2 and AVX instructions must be present in a `znver3` build and absent from an
`x86-64-v2` build. It also checks the image layout, user, entrypoint,
environment and labels. The allocator is read from `/app/BUILD-INFO`: the `musl`
variant must be free of mimalloc, and the `mimalloc` variant must contain
mimalloc **and** prove it is live at runtime — the script runs the binary with
`MIMALLOC_VERBOSE=1` and `MIMALLOC_SHOW_STATS=1` (only during the check) and
requires mimalloc's own output, rather than trusting static presence.

`verify-binary.sh` can run against an arm64 image only when qemu binfmt is
registered on the host; otherwise set `QBT_VERIFY_RUN=0` to fall back to
static-only inspection (the binary cannot be executed).

`smoke.sh` runs the image with `--read-only`, `--user 1000:1000`, tmpfs `/tmp`
and an empty `/config`, waits for the WebUI on a non-default port, logs in with
the temporary password printed on first start, and checks `/api/v2/app/version`
and `/api/v2/app/buildInfo` through loopback from inside the container. It also
checks that the process is not root, that nothing was written outside `/config`,
and that `unrar`, `7zz`, `unzip` and `qbt-unpack` actually work.

## CI

`.github/workflows/build.yml` builds and verifies on every branch push and on
`workflow_dispatch`, and pushes to `ghcr.io/swizzin/qbittorrent` only from
`main`. The matrix runs six variants on a self-hosted runner labelled `znver3`,
one at a time (`max-parallel: 1`): the amd64 builds natively, the arm64 builds
are cross-compiled on the amd64 runner. Each variant builds, verifies, smoke
tests, then (on `main`) pushes its per-arch image and immutable `sha-` tag; a
final job assembles the `base` and `10g` multi-arch manifests from the per-arch
images. Images are only pushed after the tests pass. The runner needs docker
with buildx, and qemu binfmt for the arm64 variants (the workflow registers and
then verifies it, failing clearly if binfmt is not usable). The workflow
installs `binutils` and `file` for `hack/verify-binary.sh` when they are
missing. A runner can export `BUILD_JOBS` to cap compile parallelism below the
default of 16.

## Licences

The contents of this repository are Apache-2.0 (see `LICENSE`).

The image contains qBittorrent, which is GPL-2.0-or-later, and libtorrent,
which is BSD-3-Clause, plus Qt, OpenSSL, Boost and zlib under their own
licences. Corresponding source is the upstream release tags
(qBittorrent `release-5.3.0`, libtorrent `v1.2.20`, and the versions of the
other dependencies selected by the pinned build script) plus
`patches/libtorrent/1.2.20/` from this repository.

## Credits

The build itself is [userdocs/qbittorrent-nox-static](https://github.com/userdocs/qbittorrent-nox-static),
which does the heavy lifting: musl toolchain, static Qt, Boost, OpenSSL and
libtorrent. This repository only pins it, adds the libtorrent defaults patches
and packages the result.

## AI disclosure

Built with substantial help from AI coding assistants. The maintainer directs
the design, reviews the work, and is responsible for every commit.
