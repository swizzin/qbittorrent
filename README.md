# qbittorrent

A container image of qBittorrent, built from source, in two libtorrent lines
side by side: **qBittorrent 5.3.0** on **libtorrent 1.2.20** and on
**libtorrent 2.1.2**, both statically linked against musl.

Each line is built in two compiled libtorrent profiles — **`base`** (safe on the
smallest box) and **`10g`** (tuned for a 10 Gbit seedbox) — across two targets:
**amd64** (baseline `x86-64-v2` or `znver3`) and **arm64** (`aarch64`,
cross-compiled). Each line also has its own compiled-defaults patch pair, because
a 1.2 patch does not apply to 2.x. On the 1.2.20 line the allocator is a further
axis: **`musl`** (musl's own malloc — the default) and, for its `10g-znver3`
amd64 variant, **`mimalloc`** (mimalloc v3.5.4 statically linked as a drop-in
replacement). The 2.1.2 line is musl only: the allocator A/B is a 1.2.20
experiment.

It is a drop-in replacement for a `qbittorrent-nox` container: same binary
name, same `/config` layout, same environment variables, and it runs unprivileged
with a read-only root filesystem.

## Tags

Two kinds of tag. A **moving** tag names a variant and is re-pointed at the
latest build of it. An **immutable** tag names one build of one commit and is
never re-pushed: the jobs refuse to overwrite one, so `sha-…` always means the
same image.

A tag whose last element is an architecture (`-amd64`, `-arm64`) is a single
image; a tag with no architecture is a multi-arch **manifest** over those images.

| tag | what it is |
|---|---|
| `5.3.0-lt1.2.20` | moving, libtorrent 1.2.20, `base` profile: multi-arch **manifest** (amd64 + arm64) |
| `5.3.0-lt1.2.20-10g` | moving, 1.2.20, `10g` profile, baseline CPU: multi-arch **manifest** (amd64 + arm64) |
| `5.3.0-lt1.2.20-10g-znver3` | moving, 1.2.20, `10g` profile, `znver3` amd64, `musl`: single image |
| `5.3.0-lt1.2.20-10g-znver3-mimalloc` | moving, 1.2.20, `10g` profile, `znver3` amd64, `mimalloc`: single image |
| `5.3.0-lt2.1.2` | moving, libtorrent 2.1.2, `base` profile: multi-arch **manifest** (amd64 + arm64) |
| `5.3.0-lt2.1.2-10g` | moving, 2.1.2, `10g` profile, baseline CPU: multi-arch **manifest** (amd64 + arm64) |
| `5.3.0-lt2.1.2-10g-znver3` | moving, 2.1.2, `10g` profile, `znver3` amd64, `musl`: single image |
| `sha-<12>-lt<lt>-base` | immutable, this commit's `base` **manifest** for that libtorrent line |
| `sha-<12>-lt<lt>-10g` | immutable, this commit's `10g` baseline **manifest** for that line |
| `sha-<12>-lt<lt>-<variant>-<arch>` | immutable single image: `sha-<12>-lt1.2.20-base-amd64`, `sha-<12>-lt2.1.2-10g-arm64`, `sha-<12>-lt1.2.20-10g-znver3-amd64`, `sha-<12>-lt1.2.20-10g-znver3-mimalloc-amd64` |

`<12>` is the first 12 hex digits of the commit, `<lt>` is the libtorrent line
(`1.2.20` or `2.1.2`), and `<variant>` is `base`, `10g`, `10g-znver3` or
`10g-znver3-mimalloc`. Every immutable tag is `sha-<12>-lt<lt>-<variant>`; a
single image appends its architecture to that, so no two matrix legs can ever
assemble the same immutable name and one line's tag never names another line's
image. The immutable tags carry the libtorrent line because both lines build a
`base` and a `10g` variant of every commit; without it they would collide. The
1.2.20 moving tags above are unchanged from before the 2.1 line existed.

The per-arch images a manifest is assembled from are pushed under the moving tag
per arch, as `<tag>-amd64` and `<tag>-arm64`. Those are the manifest's inputs,
re-pointed on every push, and not intended for pinning.

Pin by digest when the image itself has to stay the same:

```sh
docker pull ghcr.io/swizzin/qbittorrent@sha256:<digest>
```

## CPU requirement

- `5.3.0-lt1.2.20-10g-znver3[-mimalloc]` and `5.3.0-lt2.1.2-10g-znver3`:
  compiled with `-march=znver3 -mtune=znver3` — AMD Zen 3 (Ryzen 5000, EPYC
  7003) or newer (AVX2, BMI2, FMA, VAES, …). **On anything older the binary will
  die with SIGILL.**
- `5.3.0-lt1.2.20` and `5.3.0-lt1.2.20-10g` (amd64), and `5.3.0-lt2.1.2` and
  `5.3.0-lt2.1.2-10g` (amd64): compiled with `-march=x86-64-v2` (SSE4.2,
  POPCNT, …), the baseline that runs on any x86-64 CPU from ~2009 on.
- The arm64 images of both lines: compiled for the `armv8-a` baseline (any
  64-bit ARM server).

`verify-binary.sh` asserts the exact architecture and `-march` of every build:
the ELF machine, the recorded `.GCC.command.line` flags, and — for amd64 — an
instruction census (BMI2/AVX present in a `znver3` build, absent from an
`x86-64-v2` build).

## The build matrix

| libtorrent | profile | CPU | arch | allocator | tag |
|---|---|---|---|---|---|
| 1.2.20 | base | baseline | amd64 | musl | `5.3.0-lt1.2.20` |
| 1.2.20 | base | baseline | arm64 | musl | `5.3.0-lt1.2.20` |
| 1.2.20 | 10g | baseline | amd64 | musl | `5.3.0-lt1.2.20-10g` |
| 1.2.20 | 10g | baseline | arm64 | musl | `5.3.0-lt1.2.20-10g` |
| 1.2.20 | 10g | znver3 | amd64 | musl | `5.3.0-lt1.2.20-10g-znver3` |
| 1.2.20 | 10g | znver3 | amd64 | mimalloc | `5.3.0-lt1.2.20-10g-znver3-mimalloc` |
| 2.1.2 | base | baseline | amd64 | musl | `5.3.0-lt2.1.2` |
| 2.1.2 | base | baseline | arm64 | musl | `5.3.0-lt2.1.2` |
| 2.1.2 | 10g | baseline | amd64 | musl | `5.3.0-lt2.1.2-10g` |
| 2.1.2 | 10g | baseline | arm64 | musl | `5.3.0-lt2.1.2-10g` |
| 2.1.2 | 10g | znver3 | amd64 | musl | `5.3.0-lt2.1.2-10g-znver3` |

`base` and `10g` differ only in two compile-only libtorrent defaults
(`send_not_sent_low_watermark` and `max_peer_recv_buffer_size`); four other
tunings are shared. The two libtorrent lines share that intent but each has its
own patch pair, generated from its own tag. The runtime profiles
(`light`/`1g`/`10g`) are `qBittorrent.conf` presets, not image axes — they are
not built as tags. See [patches/libtorrent/README.md](patches/libtorrent/README.md).

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

- `qbittorrent-nox` 5.3.0, static, stripped, built on libtorrent 1.2.20 or
  2.1.2 (the image's tag and `BUILD-INFO` say which)
- `unrar` 7.23 (from `ghcr.io/linuxserver/unrar`, Alpine build)
- `7zz` 26.01 (Alpine `7zip` package, `7z` is a symlink)
- `unzip` (busybox applet)
- `qbt-unpack` at `/usr/local/bin/qbt-unpack` — post-download archive
  extraction, meant for *Options → Downloads → Run external program on torrent
  completion*: `/usr/local/bin/qbt-unpack "%F"`
- `bash`, `catatonit`, `tzdata`, `ca-certificates`

`/app/BUILD-INFO` records the exact versions (including the libtorrent line),
the CPU target, the profile, the architecture, the allocator, the sha256 of the
build script and the sha256 of the patch the image was built with.

## Patches

Each libtorrent line has its own compiled-defaults patch pair, generated from
that line's tag:

- `patches/libtorrent/1.2.20/patch` — the `10g` profile: six compiled-in
  libtorrent defaults.
- `patches/libtorrent/1.2.20/base.patch` — the `base` profile: the same six,
  except `send_not_sent_low_watermark` and `max_peer_recv_buffer_size` stay at
  the stock/baseline values.
- `patches/libtorrent/2.1.2/patch` and `patches/libtorrent/2.1.2/base.patch` —
  the same split for libtorrent 2.1.2, re-derived against that tag.

The `LT_VERSION` build arg selects the line, and its value is the directory
name the build script reads (`-lt v<LT_VERSION>`). See
[patches/libtorrent/README.md](patches/libtorrent/README.md) for what each patch
does and why, the two values that differ between the profiles, and — for 2.1.2
— why the 2.x disk settings are not in it.

qBittorrent itself is built from the `release-5.3.0` tag **unpatched**. The
build script would otherwise fetch patches for the tag from
userdocs/qbittorrent-nox-static at build time; the Dockerfile puts a
comment-only file in that module's patch directory, which makes the script take
its local (empty) patch path instead. The build asserts that exactly one patch
was applied and that the qBittorrent tree is still the pristine tag.

## Allocator variants

`ARG ALLOCATOR` selects the memory allocator. It exists on the 1.2.20 line only,
and for its `10g-znver3` amd64 variant it is the **only** difference between two
images; the 2.1.2 line is musl only.

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

`mimalloc` is only valid for the 1.2.20 `10g-znver3` amd64 line; the Dockerfile
fails any other combination, including 2.1.2 on mimalloc, and the
baseline/arm64/2.1.2 images are `musl` only. Any other `ALLOCATOR` value fails
the build. A third allocator (e.g. jemalloc) would be added the same way: a pin
for its source, a build step that produces a linkable object, a `-suffix` for
its tag in `hack/versions.sh`, and an allocator branch in `hack/verify-binary.sh`.

`/app/BUILD-INFO` records `allocator=musl|mimalloc`, plus `mimalloc_tag` and
`mimalloc_sha256` for the mimalloc variant.

## Updating

qBittorrent: change `QBT_VERSION` at the top of the Dockerfile (for example
`5.3.1`) and push. That is the whole change. The image tag, the OCI labels,
`BUILD-INFO` and both check scripts read the version from the Dockerfile through
`hack/versions.sh`, and there are no per-version qBittorrent patch files.

libtorrent: each line is pinned separately. To move a line, change its
`LT_VERSION` — for the 1.2 line that is `1.2.20`, for the 2.1 line `2.1.2` —
and regenerate that line's `patches/libtorrent/<version>/patch` and
`base.patch` from the new tag's `src/settings_pack.cpp` (see
[patches/libtorrent/README.md](patches/libtorrent/README.md)), then check they
apply. Adding a third line means its patch pair plus a value in the
`LT_VERSION` case in the Dockerfile and a matrix entry in `build.yml`;
`hack/versions.sh` accepts a line only when its patch pair is present, so a tag
can never name a libtorrent the build has no defaults for. OpenSSL: change
`OPENSSL_TAG` (it is shared by both lines). mimalloc: change `MIMALLOC_TAG` and
`MIMALLOC_SHA256` together (stay on a 3.5.x with no always-on profiler). Qt and
Boost are chosen by the pinned build script: for 1.2 it pins Boost 1.86, for 2.1
it takes the newest Boost release and Qt 6.x, so a 2.1 image's Boost and Qt
version is whatever the pinned script resolves that day. Moving to a newer build
script means updating its commit and sha256 together, for both lines.

## Building locally

Requirements: docker with buildx, ~20 GiB of free disk. The amd64 builds run
natively; the arm64 build is a cross-compile (`-ma aarch64`) inside the build, so
on an amd64 host it needs qemu binfmt to assemble the arm64 runtime image and
smoke-test it, and on an arm64 host nothing is emulated.

```sh
# base profile, baseline amd64, libtorrent 1.2.20 (the Dockerfile default line)
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

# the same on libtorrent 2.1.2: the line is LT_VERSION, everything else matches
docker buildx build --load --platform linux/amd64 \
  --build-arg LT_VERSION=2.1.2 --build-arg PROFILE=base --build-arg MARCH=x86-64-v2 \
  -t qbittorrent:5.3.0-lt2.1.2 .
docker buildx build --load --platform linux/amd64 \
  --build-arg LT_VERSION=2.1.2 \
  -t qbittorrent:5.3.0-lt2.1.2-10g-znver3 .

# arm64 (cross-compiled; qemu binfmt must be registered for the runtime stage)
docker buildx build --load --platform linux/arm64 \
  --build-arg PROFILE=base \
  -t qbittorrent:5.3.0-lt1.2.20-arm64 .
```

The build is done by [userdocs/qbittorrent-nox-static](https://github.com/userdocs/qbittorrent-nox-static)
pinned to commit `66a0aa3fd2044dcd2a327670aba35779b0957e34`, and the script
itself is pinned by sha256 in the `ADD --checksum` line. Everything else is
pinned too: qBittorrent `release-5.3.0`, the libtorrent line (`-lt v<LT_VERSION>`,
`v1.2.20` by default), OpenSSL `openssl-3.5.9` (the 3.5 LTS line: Boost's asio
TLS hostname verification does not compile against the opaque `ASN1_STRING` of
OpenSSL 4.x, and the script would otherwise take 4.x), libiconv 1.18 by sha256
(only the 1.2 line uses it), and Alpine 3.24 by digest (a multi-arch index, so
the same pin resolves amd64 and arm64). Patches are copied into the script's
patch tree before the build, so the compile step needs no network access for
patches.

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
environment and labels. Both scripts read the libtorrent line from
`/app/BUILD-INFO`, so the version string they expect and the patch they compare
against `libtorrent_patch_sha256` are the line the image was actually built on,
not the Dockerfile's default: the `musl` variant must be free of mimalloc, and a
`mimalloc` image on any line but 1.2.20 is refused outright. The `mimalloc`
variant must contain mimalloc **and** prove it is live at runtime — the script
runs the binary with `MIMALLOC_VERBOSE=1` and `MIMALLOC_SHOW_STATS=1` (only
during the check) and requires mimalloc's own output, rather than trusting
static presence.

`verify-binary.sh` can run against an arm64 image only when qemu binfmt is
registered on the host; otherwise set `QBT_VERIFY_RUN=0` to fall back to
static-only inspection (the binary cannot be executed).

`smoke.sh` runs the image with `--read-only`, `--user 1000:1000`, tmpfs `/tmp`
and an empty `/config`, waits for the WebUI on a non-default port, logs in with
the temporary password printed on first start, and checks `/api/v2/app/version`
and `/api/v2/app/buildInfo` through loopback from inside the container. It also
checks that the process is not root, that nothing was written outside `/config`,
and that `unrar`, `7zz`, `unzip` and `qbt-unpack` actually work.

### Verifying a published image

Every image and manifest pushed to `ghcr.io/swizzin/qbittorrent` is signed with
[cosign](https://github.com/sigstore/cosign) in keyless mode: the signature
carries a short-lived certificate from GitHub's OIDC issuer that names this
repository, the build workflow and the commit, so there is no long-lived signing
key to hold or leak, and a signature can only have been made by a build of this
workflow.

```sh
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity https://github.com/swizzin/qbittorrent/.github/workflows/build.yml@refs/heads/main \
  ghcr.io/swizzin/qbittorrent@sha256:<digest>
```

Verify the digest, not the moving tag: the signature is a claim about an image,
and the moving tags are re-pointed on the next push while the digest keeps
naming the same bytes.

## CI

`.github/workflows/build.yml` builds and verifies on every push to `main` and on
`workflow_dispatch`, and pushes to `ghcr.io/swizzin/qbittorrent` only from
`main`. The matrix runs eleven variants, one at a time (`max-parallel: 1`): six
on libtorrent 1.2.20 and five on 2.1.2. Each variant builds, verifies and smoke
tests, then pushes its per-arch image and an immutable tag; a final job
assembles the `base` and `10g` multi-arch manifests of both lines from the
per-arch images. Images are only pushed after the checks pass.

Where a variant runs follows from its CPU target:

| legs | runner | why |
|---|---|---|
| `*-base-amd64`, `*-10g-amd64` (`x86-64-v2`) | `ubuntu-24.04` | the baseline ISA: builds and runs on any x86-64 host |
| `*-base-arm64`, `*-10g-arm64` (`armv8-a`) | `ubuntu-24.04-arm` | native arm64: the runtime image and the smoke test are arm64 code, so nothing is emulated |
| `lt1.2.20-10g-znver3-musl`, `lt1.2.20-10g-znver3-mimalloc`, `lt2.1.2-10g-znver3-musl` | self-hosted, labelled `znver3` | a `znver3` binary dies with SIGILL on any other CPU, so its smoke test needs the target |

The `lt2.1.2` legs are the two baselines plus 10g-znver3; there is no 2.1
mimalloc leg, because the allocator A/B is a 1.2.20 experiment.

No job registers qemu binfmt: the handlers are kernel-global, so on a shared
build host that changes the host, not the container. arm64 is still a
cross-compile inside the build (the pinned build script's `-ma aarch64`), but on
an arm64 machine it runs natively.

A self-hosted runner exports `BUILD_JOBS` to cap compile parallelism, because
its pod is the thing with a CPU and memory limit; anywhere else the workflow
uses the core count, capped at the Dockerfile's default of 16. The workflow
installs `binutils` and `file` for `hack/verify-binary.sh` when they are
missing.

`.github/workflows/pull-request.yml` is the pull-request check, and it never
runs on the self-hosted runner: `pull_request` (never `pull_request_target`),
`contents: read`, no secrets, nothing built and nothing pushed. It runs
actionlint, shellcheck over `hack/*.sh`, `entrypoint.sh` and `qbt-unpack`,
hadolint over the Dockerfile, and the axis and tag scheme `hack/versions.sh`
derives. Everything else has to be checked against a built image, so
`verify-binary.sh` and `smoke.sh` run on `main` only.

## Licences

**This repository** — the Dockerfile, the CI, the scripts and the libtorrent
patches — is Apache-2.0 (see `LICENSE`). That choice is deliberate: a patch or a
script under a permissive licence can be offered upstream to libtorrent or
qBittorrent, which a copyleft one could not.

**The image is not Apache-2.0**, and its OCI label says so:

```
org.opencontainers.image.licenses="Apache-2.0 AND GPL-3.0-or-later"
```

qBittorrent's `COPYING`, at the `release-5.3.0` tag this image is built from,
is explicit about the difference:

> The qBittorrent source code is licensed under the GNU General Public License,
> version 2 or (at your option) any later version (GPLv2+). However, the binary
> distribution is licensed under GNU General Public License, version 3 or (at
> your option) any later version (GPLv3+), because it contains GPLv3+ assets
> (eg images).

This image is a binary distribution, so GPL-3.0-or-later is what applies to it;
GPLv2+ describes the source you can rebuild. qBittorrent's COPYING also carries
an OpenSSL linking exception, which is what makes linking a statically built
OpenSSL possible at all. libtorrent is BSD-3-Clause, and Qt, OpenSSL, Boost and
zlib are under their own licences.

**Corresponding source**: the upstream release tags — qBittorrent
`release-5.3.0`, libtorrent `v1.2.20` or `v2.1.2` (the line the image was
built on), OpenSSL `openssl-3.5.9` (`OPENSSL_TAG`) and the versions of the rest
that the pinned build script selects — plus that line's directory under
`patches/libtorrent/` from this repository. Every pin, and the sha256 of the
build script and of the patch the image was built with, is recorded in
`/app/BUILD-INFO` inside the image, so the source can be rebuilt exactly rather
than approximately.

Redistributing the image is redistributing qBittorrent's binary: keep the
notice, and be able to point at that source.

## Credits

The build itself is [userdocs/qbittorrent-nox-static](https://github.com/userdocs/qbittorrent-nox-static),
which does the heavy lifting: musl toolchain, static Qt, Boost, OpenSSL and
libtorrent. This repository only pins it, adds the libtorrent defaults patches
and packages the result.

## AI disclosure

Built with substantial help from AI coding assistants. The maintainer directs
the design, reviews the work, and is responsible for every commit.
