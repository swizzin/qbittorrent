# qbittorrent

A container image of qBittorrent, built from source: **qBittorrent 5.3.0** on
**libtorrent 1.2.20**, statically linked against musl, with libtorrent's
compiled-in defaults tuned for a 10 Gbit seedbox, and compiled for the
**znver3** microarchitecture.

It ships as two variants that differ **only in the memory allocator**: `musl`
(musl's own malloc — the default) and `mimalloc` (mimalloc v3.5.4 statically
linked as a drop-in replacement). Everything else — versions, the 10g
libtorrent patch, the `-march` target, the runtime — is identical, so the pair
is a fair A/B.

It is a drop-in replacement for a `qbittorrent-nox` container: same binary
name, same `/config` layout, same environment variables, and it runs unprivileged
with a read-only root filesystem.

## Tags

| tag | meaning |
|---|---|
| `5.3.0-lt1.2.20-10g-znver3` | moving tag for the `musl` allocator build |
| `5.3.0-lt1.2.20-10g-znver3-mimalloc` | moving tag for the `mimalloc` allocator build |
| `sha-<12 hex>` | immutable tag for the commit (musl variant) |
| `sha-<12 hex>-mimalloc` | immutable tag for the commit (mimalloc variant) |

## CPU requirement

The whole image — qBittorrent, libtorrent, Qt, OpenSSL, Boost, zlib — is
compiled with `-march=znver3 -mtune=znver3`. That is AMD Zen 3 (Ryzen 5000,
EPYC 7003) and any CPU that implements the same instruction set (AVX2, BMI2,
FMA, VAES, …). **On anything older the binary will die with SIGILL.**

A baseline build is one build argument away:

```sh
docker buildx build --build-arg MARCH=x86-64-v2 --load -t qbittorrent:baseline .
```

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
  ghcr.io/swizzin/qbittorrent:5.3.0-lt1.2.20-10g-znver3
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

`/app/BUILD-INFO` records the exact versions, the CPU target, the allocator,
the sha256 of the build script and the sha256 of both patches the image was
built with.

## Patches

- `patches/libtorrent/1.2.20/patch` — six compiled-in libtorrent defaults (the
  "10g" profile). See [patches/libtorrent/README.md](patches/libtorrent/README.md)
  for what each one does and why.

qBittorrent itself is built from the `release-5.3.0` tag **unpatched**. The
build script would otherwise fetch patches for the tag from
userdocs/qbittorrent-nox-static at build time; the Dockerfile puts a
comment-only file in that module's patch directory, which makes the script take
its local (empty) patch path instead. The build asserts that exactly one patch
was applied and that the qBittorrent tree is still the pristine tag.

## Allocator variants

`ARG ALLOCATOR` selects the memory allocator; it is the **only** difference
between the two images.

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

Any other `ALLOCATOR` value fails the build. A third allocator (e.g. jemalloc)
would be added the same way: a pin for its source, a build step that produces a
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
`patches/libtorrent/<version>/patch` from that tag's `src/settings_pack.cpp`
(see [patches/libtorrent/README.md](patches/libtorrent/README.md)) and check it
applies. OpenSSL: change `OPENSSL_TAG`. mimalloc: change `MIMALLOC_TAG` and
`MIMALLOC_SHA256` together (stay on a 3.5.x with no always-on profiler). Qt and
Boost are chosen by the pinned build script; moving to a newer build script
means updating its commit and sha256 together.

## Building locally

Requirements: docker with buildx, ~20 GiB of free disk, and a Zen 3 (or newer)
host — the build runs natively, not under emulation.

```sh
docker buildx build --load -t qbittorrent:5.3.0-lt1.2.20-10g-znver3 .
docker buildx build --load -t qbittorrent:5.3.0-lt1.2.20-10g-znver3-mimalloc \
  --build-arg ALLOCATOR=mimalloc .
```

The build is done by [userdocs/qbittorrent-nox-static](https://github.com/userdocs/qbittorrent-nox-static)
pinned to commit `66a0aa3fd2044dcd2a327670aba35779b0957e34`, and the script
itself is pinned by sha256 in the `ADD --checksum` line. Everything else is
pinned too: qBittorrent `release-5.3.0`, libtorrent `v1.2.20`, OpenSSL
`openssl-3.5.9` (the 3.5 LTS line: libtorrent 1.2 pulls Boost 1.86, whose asio
TLS hostname verification does not compile against the opaque `ASN1_STRING` of
OpenSSL 4.x), libiconv 1.18 by sha256, and Alpine 3.24 by digest. Patches are
copied into the script's patch tree before the build, so the compile step needs
no network access for patches.

About 10–15 minutes on a 24-thread Zen 3 host. `--build-arg BUILD_JOBS=`
controls parallelism; the default is 16 to stay inside 32 GiB of RAM.

The Dockerfile fails the build if the libtorrent patch did not apply, if the
qBittorrent tree was patched, if the patched source is not the source that was
compiled, or if the compiler was not invoked with the target `-march`. Patch
application is not otherwise fatal in the upstream script, so this check is the
real gate.

## Verifying

```sh
hack/verify-binary.sh qbittorrent:5.3.0-lt1.2.20-10g-znver3
hack/verify-binary.sh qbittorrent:5.3.0-lt1.2.20-10g-znver3-mimalloc
hack/smoke.sh        qbittorrent:5.3.0-lt1.2.20-10g-znver3
hack/smoke.sh        qbittorrent:5.3.0-lt1.2.20-10g-znver3-mimalloc
```

`verify-binary.sh` inspects the stripped binary: qBittorrent and libtorrent
version strings, absence of gcov/profiling/tcmalloc artefacts, static linkage,
the recorded compiler flags (`.GCC.command.line`, written by
`-frecord-gcc-switches` and preserved through `-s` and LTO) and an instruction
census (BMI2 and AVX instructions, which a baseline x86-64 build cannot
contain). It also checks the image layout, user, entrypoint, environment and
labels. The allocator is read from `/app/BUILD-INFO`: the `musl` variant must be
free of mimalloc, and the `mimalloc` variant must contain mimalloc **and** prove
it is live at runtime — the script runs the binary with `MIMALLOC_VERBOSE=1`
and `MIMALLOC_SHOW_STATS=1` (only during the check) and requires mimalloc's own
output, rather than trusting static presence.

`smoke.sh` runs the image with `--read-only`, `--user 1000:1000`, tmpfs `/tmp`
and an empty `/config`, waits for the WebUI on a non-default port, logs in with
the temporary password printed on first start, and checks `/api/v2/app/version`
and `/api/v2/app/buildInfo` through loopback from inside the container. It also
checks that the process is not root, that nothing was written outside `/config`,
and that `unrar`, `7zz`, `unzip` and `qbt-unpack` actually work.

## CI

`.github/workflows/build.yml` runs a matrix over the two allocators on a
self-hosted runner labelled `znver3`, one runner pod at a time
(`max-parallel: 1`): for each of `musl` and `mimalloc` it builds, verifies,
smoke tests, then pushes to `ghcr.io/swizzin/qbittorrent` with both tags (the
moving tag and the `sha-<12>` tag, the latter suffixed `-mimalloc` for the
mimalloc variant). Images are only pushed after the tests pass. The runner
needs docker with buildx; the workflow installs `binutils` and `file` for
`hack/verify-binary.sh` when they are missing. A runner can export
`BUILD_JOBS` to cap compile parallelism below the default of 16.

## Licences

The contents of this repository are Apache-2.0 (see `LICENSE`).

The image contains qBittorrent, which is GPL-2.0-or-later, and libtorrent,
which is BSD-3-Clause, plus Qt, OpenSSL, Boost and zlib under their own
licences. Corresponding source is the upstream release tags
(qBittorrent `release-5.3.0`, libtorrent `v1.2.20`, and the versions of the
other dependencies selected by the pinned build script) plus
`patches/libtorrent/1.2.20/patch` from this repository.

## Credits

The build itself is [userdocs/qbittorrent-nox-static](https://github.com/userdocs/qbittorrent-nox-static),
which does the heavy lifting: musl toolchain, static Qt, Boost, OpenSSL and
libtorrent. This repository only pins it, adds the libtorrent defaults patch and
packages the result.

## AI disclosure

Built with substantial help from AI coding assistants. The maintainer directs
the design, reviews the work, and is responsible for every commit.
