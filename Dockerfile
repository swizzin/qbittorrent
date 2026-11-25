# syntax=docker/dockerfile:1.7
#
# qBittorrent on libtorrent (two lines, versions below), statically linked
# against musl.
#
# The image is built in two compiled libtorrent profiles (base and 10g) across
# two targets: amd64 (baseline x86-64-v2 or znver3) and arm64 (aarch64). Two
# libtorrent lines are maintained side by side, 1.2.20 and 2.1.2, each with its
# own compiled-defaults patch pair. The allocator follows the profile, on every
# line and every target: base keeps musl's own malloc, 10g links mimalloc.
#
# The build is done by userdocs/qbittorrent-nox-static, pinned to a commit and
# to the sha256 of the script itself. Patches are taken from this repository
# only; they are copied into the script's patch tree before the build so its
# "local patches" path is used and nothing is fetched from the network while
# compiling. Each architecture is built natively, on a host of its own
# architecture: the script's native path, the same one on amd64 and arm64, with
# no cross toolchain and no prebuilt host tools.

# The versions. Updating qBittorrent is a change to QBT_VERSION and nothing else.
ARG QBT_VERSION=5.3.1

# The libtorrent line, as its exact tag version. Both lines are built and
# maintained side by side:
#
#   1.2.20  the line the 10g images and the znver3 target started on
#   2.1.2   the 2.1 line
#
# Each has its own compiled-defaults patch pair under
# patches/libtorrent/<version>/, which is also the directory the build script
# reads when it is given -lt v<version>, so the version and the patch always
# travel together. A version with no pair there is a build error.
ARG LT_VERSION=1.2.20

# The memory allocator, as a build arg because the image records it in
# BUILD-INFO and its OCI description and hack/verify-binary.sh reads it back.
# It is not a free axis: it follows the profile. base keeps musl's own malloc;
# 10g links mimalloc v3.7.1 as a statically linked drop-in replacement, on every
# libtorrent line and every target, so a 10g tag names one allocator and no tag
# has to say which. Any pairing other than base+musl or 10g+mimalloc fails the
# build, and so does any other value. The default matches the default PROFILE
# below.
ARG ALLOCATOR=mimalloc

# The compiled libtorrent profile. base and 10g differ only in the two
# compile-only defaults that scale with the box (send_not_sent_low_watermark and
# max_peer_recv_buffer_size); the other four tunings are shared, and the
# profile also selects the allocator (see ALLOCATOR above). The runtime
# profiles (light/1g/10g) are qBittorrent.conf presets, not build axes, so they
# are not image tags here. Any other value fails the build.
ARG PROFILE=10g

ARG ALPINE_IMAGE=docker.io/library/alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a
ARG UNRAR_IMAGE=ghcr.io/linuxserver/unrar@sha256:48c0ce2609bb3c35764956bbd9395e95b177421e3c74b3628c3676029f24f2e0

###############################################################################
# build
###############################################################################
# The build stage runs on the target platform: an arm64 image is compiled by an
# arm64 Alpine with its own toolchain, exactly as an amd64 one is. CI builds
# every leg on a runner of the leg's architecture, so nothing is emulated. On a
# host of the other architecture the stage needs qemu binfmt and runs the whole
# compile emulated, which works and takes hours.
FROM --platform=${TARGETPLATFORM} ${ALPINE_IMAGE} AS build

# BuildKit fills these in from --platform. They carry no default on purpose: a
# default here wins over BuildKit's value, so an arm64 build would see amd64
# and take the amd64 branches below.
ARG TARGETPLATFORM
ARG TARGETARCH

# Microarchitecture target for amd64. This is the single knob for a baseline
# build:
#   docker buildx build --build-arg MARCH=x86-64-v2 ...
# It is ignored for arm64, which is always built for the armv8-a baseline.
ARG MARCH=znver3
ARG BUILD_JOBS=16
ARG QBT_VERSION
ARG LT_VERSION
ARG ALLOCATOR
ARG PROFILE
ARG QBT_TAG=release-${QBT_VERSION}
ARG LT_TAG=v${LT_VERSION}

# OpenSSL is pinned to the 3.5 LTS line for both libtorrent lines. libtorrent
# 1.2 pulls Boost 1.86, whose asio TLS hostname verification reads ASN1_STRING
# fields directly; OpenSSL 4.x made those types opaque, so 4.x does not compile.
# The 2.1 line takes a newer Boost (pinned below), but one OpenSSL pin for
# both lines is one thing to reason about, and 3.5 is the supported LTS line
# (3.4 went end-of-life in October 2026).
ARG OPENSSL_TAG=openssl-3.5.9

# Boost is pinned per libtorrent line. The script defaults 1.2 to Boost 1.86.0
# but resolves the newest Boost release for 2.x at build time, so without a pin
# two lt2 builds of one commit could link different Boost releases. Bumping it is
# a one-line change here, like every other pin.
ARG BOOST_TAG_LT1_2=boost-1.86.0
ARG BOOST_TAG_LT2_1=boost-1.92.0

# userdocs/qbittorrent-nox-static @ 66a0aa3fd2044dcd2a327670aba35779b0957e34
ARG QBT_STATIC_SCRIPT_URL=https://raw.githubusercontent.com/userdocs/qbittorrent-nox-static/66a0aa3fd2044dcd2a327670aba35779b0957e34/qbittorrent-nox-static.sh
ARG QBT_STATIC_SCRIPT_SHA256=0a865a0c09b2621feb05f0e16b9ac29263d7b3bdd0a1e3b8b8ba062925a3637c

# libiconv is the one module the script resolves through ftpmirror.gnu.org's
# redirector, which hands out mirrors that are not always reachable. The source
# is therefore pinned here and handed to the script through its cache-directory
# option instead. Only the 1.2 line builds it (the script drops iconv for 2.x);
# it is fetched for both so the cache step below is unconditional and identical.
ARG ICONV_VERSION=1.18
ARG ICONV_SHA256=3b08f5f4f9b4eb82f151a7040bfd6fe6c6fb922efe4b1659c66ea933276965e8

# mimalloc, the allocator every 10g build links. A Release build of it is not
# the plain allocator by default (statistics and sampled profiling are on; see
# the mimalloc stage below), so a bump re-reads its CMake defaults. The release
# tarball is pinned by sha256 like the other sources.
ARG MIMALLOC_TAG=v3.7.1
ARG MIMALLOC_SHA256=8bc9f820eaf3dad3509d7930d80c40512bc51e04989641f892ee64c46b7ab0d8

SHELL ["/bin/sh", "-c"]
ENV CMAKE_BUILD_PARALLEL_LEVEL=${BUILD_JOBS}

# The script installs its own build dependencies; these four are what it needs
# before it can bootstrap. Package versions are not pinned: apk resolves them
# from the pinned Alpine release branch's index at build time, so they take
# that branch's security fixes, and the pushed image's digest is what records
# the exact packages a build got.
# hadolint ignore=DL3018
RUN apk add --no-cache bash git curl ca-certificates

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

WORKDIR /build

# A bad value for any build axis is a build error rather than a silent fallback.
RUN case "${ALLOCATOR}" in \
        musl|mimalloc) ;; \
        *) printf 'ALLOCATOR must be "musl" or "mimalloc", got: %s\n' "${ALLOCATOR}" >&2; exit 1;; \
    esac; \
    case "${PROFILE}" in \
        base|10g) ;; \
        *) printf 'PROFILE must be "base" or "10g", got: %s\n' "${PROFILE}" >&2; exit 1;; \
    esac; \
    case "${LT_VERSION}" in \
        1.2.20|2.1.2) ;; \
        *) printf 'LT_VERSION must be "1.2.20" or "2.1.2", got: %s\n' "${LT_VERSION}" >&2; exit 1;; \
    esac; \
    case "${TARGETARCH}" in \
        amd64|arm64) ;; \
        *) printf 'TARGETARCH must be "amd64" or "arm64", got: %s\n' "${TARGETARCH}" >&2; exit 1;; \
    esac; \
    case "${PROFILE}:${ALLOCATOR}" in \
        base:musl|10g:mimalloc) ;; \
        *) printf 'the allocator follows the profile (base is musl, 10g is mimalloc), got PROFILE=%s ALLOCATOR=%s\n' "${PROFILE}" "${ALLOCATOR}" >&2; exit 1;; \
    esac

# Fetched, not copied: COPY cannot read a URL, and --checksum is what pins the
# download to QBT_STATIC_SCRIPT_SHA256 above.
# hadolint ignore=DL3020
ADD --checksum=sha256:${QBT_STATIC_SCRIPT_SHA256} \
    ${QBT_STATIC_SCRIPT_URL} \
    /build/qbittorrent-nox-static.sh

COPY patches/ /build/patches/

ADD --checksum=sha256:${ICONV_SHA256} \
    https://ftp.gnu.org/gnu/libiconv/libiconv-${ICONV_VERSION}.tar.gz \
    /build/cache/iconv.tar.gz

ADD --checksum=sha256:${MIMALLOC_SHA256} \
    https://github.com/microsoft/mimalloc/archive/refs/tags/${MIMALLOC_TAG}.tar.gz \
    /build/mimalloc.tar.gz

RUN set -eux; \
    tar -xzf /build/cache/iconv.tar.gz -C /build/cache; \
    mv "/build/cache/libiconv-${ICONV_VERSION}" /build/cache/iconv; \
    rm -f /build/cache/iconv.tar.gz; \
    test -f /build/cache/iconv/configure

# 1. bootstrap: creates qbt-build/ with the patch directories for the pinned
#    tags and installs the build dependencies from Alpine. There is no -ma flag:
#    the script builds for the architecture it runs on, with the host toolchain,
#    on arm64 as on amd64.
# 2. install the libtorrent patch for the selected line and profile. A local
#    patch file takes priority over the script's remote patch repository, so the
#    build is reproducible.
# 3. qBittorrent is built from its upstream tag with no patches. The script
#    falls back to fetching patches from its own repository for a tag it has no
#    local patch for, so the version's patch directory gets a comment-only
#    "url" file: that marks the module as locally patched, and because every
#    line is a comment nothing is downloaded and nothing is applied.
RUN set -eux; \
    case "${PROFILE}" in \
        base) patch_src="base.patch" ;; \
        10g) patch_src="patch" ;; \
    esac; \
    case "${LT_VERSION}" in \
        1.2.*) boost_tag="${BOOST_TAG_LT1_2}" ;; \
        2.1.*) boost_tag="${BOOST_TAG_LT2_1}" ;; \
        *) printf 'no Boost pin for libtorrent %s\n' "${LT_VERSION}" >&2; exit 1 ;; \
    esac; \
    bash qbittorrent-nox-static.sh -lt "${LT_TAG}" -qt "${QBT_TAG}" -ot "${OPENSSL_TAG}" -bt "${boost_tag}" -bs-a; \
    install -D -m 0644 "/build/patches/libtorrent/${LT_VERSION}/${patch_src}" "/build/qbt-build/patches/libtorrent/${LT_VERSION}/patch"; \
    test -s "/build/qbt-build/patches/libtorrent/${LT_VERSION}/patch"; \
    printf '%s\n' \
        '# qBittorrent is built from its upstream release tag with no patches.' \
        '# A non-empty url file is how qbittorrent-nox-static is told to use its' \
        '# local patch path instead of its remote patch repository; every line' \
        '# here is a comment, so nothing is downloaded and nothing is applied.' \
        > "/build/qbt-build/patches/qbittorrent/${QBT_VERSION}/url"; \
    test -s "/build/qbt-build/patches/qbittorrent/${QBT_VERSION}/url"

# mimalloc (the 10g allocator): build the single object file that, linked on
# the final link line, replaces malloc/free/calloc/realloc/
# aligned_alloc/posix_memalign/memalign/malloc_usable_size. MI_LIBC_MUSL selects
# the musl TLS model; MI_OVERRIDE emits the strong override symbols;
# MI_SECURE=OFF and a Release build keep mimalloc at its default behaviour. It
# is compiled with the same per-target flags as everything else below: arm64 is
# the armv8-a baseline, an amd64 baseline (-march=x86-64-v2) tunes for generic,
# and a znver3 build tunes for znver3. MI_NO_OPT_ARCH keeps mimalloc's own
# target out of it: by default its CMake adds -march=armv8.1-a on arm64 (for
# LSE atomics), which would make the baseline image fault on an ARMv8.0 core
# such as the Cortex-A72. The build fails unless our -march is recorded in the
# object and no other -march is.
#
# MI_STATS and MI_PROFILE are both on by default in a Release build: the first
# counts every allocation and free (it only feeds MIMALLOC_SHOW_STATS), the
# second samples allocations for mimalloc's profiler. Nothing here reads either,
# so both are off, and the build fails unless mimalloc's own configure output
# says so.
RUN set -eux; \
    if [ "${ALLOCATOR}" = "mimalloc" ]; then \
        if [ "${TARGETARCH}" = "arm64" ]; then \
            march=armv8-a; \
            flags="-march=${march} -frecord-gcc-switches"; \
        else \
            march="${MARCH}"; \
            case "${MARCH}" in \
                x86-64*) mtune=generic ;; \
                *) mtune="${MARCH}" ;; \
            esac; \
            flags="-march=${march} -mtune=${mtune} -frecord-gcc-switches"; \
        fi; \
        mkdir -p /build/mimalloc/src /build/mimalloc/build; \
        tar -xzf /build/mimalloc.tar.gz -C /build/mimalloc/src --strip-components=1; \
        rm -f /build/mimalloc.tar.gz; \
        cmake -S /build/mimalloc/src -B /build/mimalloc/build -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DMI_OVERRIDE=ON \
            -DMI_BUILD_OBJECT=ON \
            -DMI_BUILD_SHARED=OFF \
            -DMI_BUILD_STATIC=ON \
            -DMI_BUILD_TESTS=OFF \
            -DMI_SECURE=OFF \
            -DMI_DEBUG=OFF \
            -DMI_LIBC_MUSL=ON \
            -DMI_NO_OPT_ARCH=ON \
            -DMI_STATS=OFF \
            -DMI_PROFILE=OFF \
            -DCMAKE_C_FLAGS="${flags}" | tee /build/mimalloc/configure.log; \
        grep -qF 'Disable detailed statistics' /build/mimalloc/configure.log; \
        grep -qF 'Disable profiling' /build/mimalloc/configure.log; \
        cmake --build /build/mimalloc/build; \
        test -s /build/mimalloc/build/mimalloc.o; \
        readelf -p .GCC.command.line /build/mimalloc/build/mimalloc.o > /build/mimalloc/cmdline.txt; \
        grep -qF -- "-march=${march}" /build/mimalloc/cmdline.txt; \
        if awk -v m="-march=${march}" '{ for (i = 1; i <= NF; i++) if ($i ~ /^-march=/ && $i != m) bad = 1 } END { exit !bad }' /build/mimalloc/cmdline.txt; then \
            printf 'mimalloc.o was compiled for another target as well as %s:\n' "${march}" >&2; \
            grep -oE -- '-march=[^ ]+' /build/mimalloc/cmdline.txt >&2; \
            exit 1; \
        fi; \
    fi

# The script appends CFLAGS/CXXFLAGS/LDFLAGS from the environment to its own
# flags, so this is how the target is set for every module it builds (zlib,
# openssl, boost, Qt, libtorrent, qBittorrent). amd64 carries -march/-mtune for
# the chosen microarchitecture (GCC takes x86-64-v2 for -march only, so the
# baseline tunes for generic); arm64 carries -march=armv8-a so the recorded
# flags name the baseline AArch64 target. For 10g every build, on both targets,
# the LDFLAGS also carry mimalloc.o, which the script appends at the end of the
# qbittorrent link line; the driver links libc.a after that, so musl's own
# malloc objects are never pulled in and the override is clean (no -z muldefs).
#
# -frecord-gcc-switches records the compiler flags in .GCC.command.line, which
# survives -s/LTO and is what hack/verify-binary.sh reads back out of the
# stripped binary.
#
# -n keeps the extracted sources and the CMake build trees so the assertions
# below can inspect them.
#
# The script's output goes to a file rather than to the build log: buildx
# clips its own log at 2 MiB, which hides the compiler error that actually
# failed. On failure only the tail of the build log and of the per-module logs
# the script writes are printed.
RUN set -eu; \
    if [ "${TARGETARCH}" = "arm64" ]; then \
        flags="-march=armv8-a -frecord-gcc-switches"; \
        ldflags=""; \
    else \
        case "${MARCH}" in \
            x86-64*) mtune=generic ;; \
            *) mtune="${MARCH}" ;; \
        esac; \
        flags="-march=${MARCH} -mtune=${mtune} -frecord-gcc-switches"; \
        ldflags="-march=${MARCH}"; \
    fi; \
    if [ "${ALLOCATOR}" = "mimalloc" ]; then \
        if [ -z "${ldflags}" ]; then \
            ldflags="/build/mimalloc/build/mimalloc.o"; \
        else \
            ldflags="${ldflags} /build/mimalloc/build/mimalloc.o"; \
        fi; \
    fi; \
    export CFLAGS="${flags}" CXXFLAGS="${flags}" LDFLAGS="${ldflags}"; \
    case "${LT_VERSION}" in \
        1.2.*) boost_tag="${BOOST_TAG_LT1_2}" ;; \
        2.1.*) boost_tag="${BOOST_TAG_LT2_1}" ;; \
        *) printf 'no Boost pin for libtorrent %s\n' "${LT_VERSION}" >&2; exit 1 ;; \
    esac; \
    if ! bash qbittorrent-nox-static.sh -lt "${LT_TAG}" -qt "${QBT_TAG}" -ot "${OPENSSL_TAG}" -bt "${boost_tag}" -cd /build/cache -n all > /build/build.log 2>&1; then \
        echo "=== build failed: tail -n 200 of /build/build.log ==="; \
        tail -n 200 /build/build.log; \
        for log in /build/qbt-build/logs/*.log; do \
            [ -f "${log}" ] || continue; \
            echo "=== ${log} (tail -n 100) ==="; \
            tail -n 100 "${log}"; \
        done; \
        find /build/qbt-build -maxdepth 3 -name config.log | while read -r log; do \
            grep -q 'exit status [1-9]\|error:' "${log}" || continue; \
            echo "=== ${log} (first errors) ==="; \
            grep -n -m 20 -B 3 'error\|exit status [1-9]' "${log}"; \
        done; \
        exit 1; \
    fi; \
    tail -n 20 /build/build.log

# Fail the build unless the libtorrent patch really was applied, unless the
# patched source is what got compiled, unless qBittorrent was left unpatched,
# and unless the compiler was really invoked with the target flags. The script
# warns and carries on when a patch fails, so this step is the actual gate.
# The two values that scale with the box differ by profile; the other four
# tunings are shared. The build stage is the target architecture, so the binary
# is executed for its version on both.
RUN set -eux; \
    bin=/build/qbt-build/completed/qbittorrent-nox; \
    test -x "${bin}"; \
    test "$(grep -c 'Patch applied successfully' /build/build.log)" -eq 1; \
    test "$(grep -c 'Applying:' /build/build.log)" -eq 1; \
    test "$(grep -c 'Using local patches method' /build/build.log)" -ge 2; \
    command -v ninja; \
    lt_src=$(echo /build/qbt-build/libtorrent-rasterbar-*/src); \
    case "${PROFILE}" in \
        base) watermark='SET(send_not_sent_low_watermark, 524288, nullptr)'; recvbuf='SET(max_peer_recv_buffer_size, 2 * 1024 * 1024, nullptr)' ;; \
        10g) watermark='SET(send_not_sent_low_watermark, 1024 * 1024, nullptr)'; recvbuf='SET(max_peer_recv_buffer_size, 4 * 1024 * 1024, nullptr)' ;; \
    esac; \
    if [ "${TARGETARCH}" = "arm64" ]; then march="armv8-a"; else march="${MARCH}"; fi; \
    grep -qF 'SET(request_timeout, 20, nullptr)' "${lt_src}/settings_pack.cpp"; \
    grep -qF 'SET(whole_pieces_threshold, 10, nullptr)' "${lt_src}/settings_pack.cpp"; \
    grep -qF "${recvbuf}" "${lt_src}/settings_pack.cpp"; \
    grep -qF 'SET(torrent_connect_boost, 50, nullptr)' "${lt_src}/settings_pack.cpp"; \
    grep -qF 'SET(predictive_piece_announce, 10, nullptr)' "${lt_src}/settings_pack.cpp"; \
    grep -qF "${watermark}" "${lt_src}/settings_pack.cpp"; \
    grep -qF -- "-march=${march}" /build/qbt-build/libtorrent-rasterbar-*/build/CMakeCache.txt; \
    grep -qF -- "-march=${march}" /build/qbt-build/qBittorrent-*/build/CMakeCache.txt; \
    ninja -C "$(echo /build/qbt-build/libtorrent-rasterbar-*/build)" -t commands > /build/ninja-libtorrent.txt; \
    awk -v m="-march=${march}" 'index($0, "settings_pack.cpp.o") && index($0, m) { found = 1 } END { exit !found }' /build/ninja-libtorrent.txt; \
    ninja -C "$(echo /build/qbt-build/qBittorrent-*/build)" -t commands > /build/ninja-qbittorrent.txt; \
    awk -v m="-march=${march}" 'index($0, "sessionimpl.cpp.o") && index($0, m) { found = 1 } END { exit !found }' /build/ninja-qbittorrent.txt; \
    "${bin}" --version > /build/version.txt; \
    grep -qF "v${QBT_VERSION}" /build/version.txt; \
    if [ "${ALLOCATOR}" = "mimalloc" ]; then \
        grep -qF 'mimalloc' "${bin}"; \
        readelf -p .GCC.command.line "${bin}" | grep -qF -- "-march=${march}"; \
    fi

# Provenance for the runtime image: what was built, with which target, the
# profile, the allocator, and the exact patch consumed from this repository.
RUN set -eux; \
    case "${PROFILE}" in \
        base) patch_src="base.patch" ;; \
        10g) patch_src="patch" ;; \
    esac; \
    if [ "${TARGETARCH}" = "arm64" ]; then march="armv8-a"; else march="${MARCH}"; fi; \
    { \
        echo "qbittorrent=${QBT_VERSION}"; \
        echo "qbittorrent_patches=none"; \
        echo "libtorrent=${LT_VERSION}"; \
        echo "profile=${PROFILE}"; \
        echo "arch=${TARGETARCH}"; \
        echo "march=${march}"; \
        echo "build_jobs=${BUILD_JOBS}"; \
        echo "allocator=${ALLOCATOR}"; \
        echo "libtorrent_patch_sha256=$(sha256sum "/build/patches/libtorrent/${LT_VERSION}/${patch_src}" | cut -d' ' -f1)"; \
        echo "build_script_sha256=${QBT_STATIC_SCRIPT_SHA256}"; \
        if [ "${ALLOCATOR}" = "mimalloc" ]; then \
            echo "mimalloc_tag=${MIMALLOC_TAG}"; \
            echo "mimalloc_sha256=${MIMALLOC_SHA256}"; \
            echo "mimalloc_stats=off"; \
            echo "mimalloc_profile=off"; \
        fi; \
    } > /build/BUILD-INFO; \
    cat /build/BUILD-INFO

###############################################################################
# runtime
###############################################################################
FROM --platform=${TARGETPLATFORM} ${UNRAR_IMAGE} AS unrar

FROM --platform=${TARGETPLATFORM} ${ALPINE_IMAGE} AS runtime

ARG TARGETPLATFORM
ARG QBT_VERSION
ARG LT_VERSION
ARG MARCH=znver3
ARG ALLOCATOR=mimalloc

LABEL org.opencontainers.image.source="https://github.com/swizzin/qbittorrent" \
      org.opencontainers.image.licenses="Apache-2.0 AND GPL-3.0-or-later" \
      org.opencontainers.image.version="${QBT_VERSION}" \
      org.opencontainers.image.description="qBittorrent ${QBT_VERSION} on libtorrent ${LT_VERSION}, static musl, compiled for ${MARCH}, ${ALLOCATOR} malloc"

# The runtime tools. Versions are not pinned here either: like the build stage,
# apk takes them from the Alpine release branch's index at build time, and the
# pushed digest records what a build shipped.
# hadolint ignore=DL3018
RUN apk add --no-cache catatonit tzdata ca-certificates bash 7zip

COPY --from=build /build/qbt-build/completed/qbittorrent-nox /app/qbittorrent-nox
COPY --from=build /build/BUILD-INFO /app/BUILD-INFO
COPY --from=unrar /usr/bin/unrar-alpine /usr/bin/unrar
COPY qbt-unpack /usr/local/bin/qbt-unpack
COPY entrypoint.sh /entrypoint.sh

RUN set -eux; \
    chown 0:0 /app/qbittorrent-nox /usr/bin/unrar /usr/local/bin/qbt-unpack /entrypoint.sh; \
    chmod 0755 /app/qbittorrent-nox /usr/bin/unrar /usr/local/bin/qbt-unpack /entrypoint.sh; \
    install -d -o 65534 -g 65534 -m 0755 /config

ENV QBT_CONFIRM_LEGAL_NOTICE=1 \
    HOME=/config \
    XDG_CONFIG_HOME=/config \
    XDG_DATA_HOME=/config

USER 65534:65534
WORKDIR /config
VOLUME /config
EXPOSE 8080

ENTRYPOINT ["/usr/bin/catatonit", "--", "/entrypoint.sh"]
