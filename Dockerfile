# syntax=docker/dockerfile:1.7
#
# qBittorrent on libtorrent 1.2 (versions below), statically linked against musl and
# compiled for the znver3 microarchitecture.
#
# The build is done by userdocs/qbittorrent-nox-static, pinned to a commit and
# to the sha256 of the script itself. Patches are taken from this repository
# only; they are copied into the script's patch tree before the build so its
# "local patches" path is used and nothing is fetched from the network while
# compiling.

# The versions. Updating qBittorrent is a change to QBT_VERSION and nothing else.
ARG QBT_VERSION=5.3.0
ARG LT_VERSION=1.2.20

# The allocator is the one axis of the A/B image pair. musl (the default) keeps
# musl's own malloc; mimalloc links mimalloc v3.5.4 as a statically linked
# drop-in replacement. Everything else (versions, the 10g libtorrent patch, the
# -march target, the runtime) is identical across the two variants. Any other
# value fails the build.
ARG ALLOCATOR=musl

ARG ALPINE_IMAGE=docker.io/library/alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a
ARG UNRAR_IMAGE=ghcr.io/linuxserver/unrar@sha256:48c0ce2609bb3c35764956bbd9395e95b177421e3c74b3628c3676029f24f2e0

###############################################################################
# build
###############################################################################
FROM ${ALPINE_IMAGE} AS build

# Microarchitecture target. This is the single knob for a baseline build:
#   docker buildx build --build-arg MARCH=x86-64-v2 ...
ARG MARCH=znver3
ARG BUILD_JOBS=16
ARG QBT_VERSION
ARG LT_VERSION
ARG ALLOCATOR
ARG QBT_TAG=release-${QBT_VERSION}
ARG LT_TAG=v${LT_VERSION}

# OpenSSL is pinned to the 3.5 LTS line. libtorrent 1.2 pulls Boost 1.86,
# whose asio TLS hostname verification reads ASN1_STRING fields directly;
# OpenSSL 4.x made those types opaque, so 4.x does not compile. 3.5 is the
# supported LTS line (3.4 went end-of-life in October 2026).
ARG OPENSSL_TAG=openssl-3.5.9

# userdocs/qbittorrent-nox-static @ 66a0aa3fd2044dcd2a327670aba35779b0957e34
ARG QBT_STATIC_SCRIPT_URL=https://raw.githubusercontent.com/userdocs/qbittorrent-nox-static/66a0aa3fd2044dcd2a327670aba35779b0957e34/qbittorrent-nox-static.sh
ARG QBT_STATIC_SCRIPT_SHA256=0a865a0c09b2621feb05f0e16b9ac29263d7b3bdd0a1e3b8b8ba062925a3637c

# libiconv is the one module the script resolves through ftpmirror.gnu.org's
# redirector, which hands out mirrors that are not always reachable. The source
# is therefore pinned here and handed to the script through its cache-directory
# option instead.
ARG ICONV_VERSION=1.18
ARG ICONV_SHA256=3b08f5f4f9b4eb82f151a7040bfd6fe6c6fb922efe4b1659c66ea933276965e8

# mimalloc, the allocator for the ALLOCATOR=mimalloc variant. v3.5.4 is the last
# of the 3.5 line: v3.6.0 added an always-on profiler, which would contaminate a
# fair allocator comparison. The release tarball is pinned by sha256 like the
# other sources.
ARG MIMALLOC_TAG=v3.5.4
ARG MIMALLOC_SHA256=36e9b5bf1bb703567a0347491721ce2098000db8284dc55cd53d211452723cdb

SHELL ["/bin/sh", "-c"]
ENV CMAKE_BUILD_PARALLEL_LEVEL=${BUILD_JOBS}

# The script installs its own build dependencies; these four are what it needs
# before it can bootstrap.
RUN apk add --no-cache bash git curl ca-certificates

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

WORKDIR /build

# The allocator is the only thing the two variants differ on; a bad value is a
# build error rather than a silent fallback.
RUN case "${ALLOCATOR}" in \
        musl|mimalloc) ;; \
        *) printf 'ALLOCATOR must be "musl" or "mimalloc", got: %s\n' "${ALLOCATOR}" >&2; exit 1;; \
    esac

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
#    tags and installs the host build dependencies.
# 2. install our libtorrent patch. A local patch file takes priority over the
#    script's remote patch repository, so the build is reproducible.
# 3. qBittorrent is built from its upstream tag with no patches. The script
#    falls back to fetching patches from its own repository for a tag it has no
#    local patch for, so the version's patch directory gets a comment-only
#    "url" file: that marks the module as locally patched, and because every
#    line is a comment nothing is downloaded and nothing is applied.
RUN set -eux; \
    bash qbittorrent-nox-static.sh -lt "${LT_TAG}" -qt "${QBT_TAG}" -ot "${OPENSSL_TAG}" -bs-a; \
    install -D -m 0644 "/build/patches/libtorrent/${LT_VERSION}/patch" "/build/qbt-build/patches/libtorrent/${LT_VERSION}/patch"; \
    test -s "/build/qbt-build/patches/libtorrent/${LT_VERSION}/patch"; \
    printf '%s\n' \
        '# qBittorrent is built from its upstream release tag with no patches.' \
        '# A non-empty url file is how qbittorrent-nox-static is told to use its' \
        '# local patch path instead of its remote patch repository; every line' \
        '# here is a comment, so nothing is downloaded and nothing is applied.' \
        > "/build/qbt-build/patches/qbittorrent/${QBT_VERSION}/url"; \
    test -s "/build/qbt-build/patches/qbittorrent/${QBT_VERSION}/url"

# mimalloc (ALLOCATOR=mimalloc only): build the single object file that, linked
# first on the final link line, replaces malloc/free/calloc/realloc/
# aligned_alloc/posix_memalign/memalign/malloc_usable_size. MI_LIBC_MUSL selects
# the musl TLS model; MI_OVERRIDE emits the strong override symbols;
# MI_SECURE=OFF and a Release build keep mimalloc at its default (fair)
# behaviour. It is compiled with the same -march/-mtune/-frecord-gcc-switches
# flags as everything else, and the build fails unless that is actually
# recorded in the object.
RUN set -eux; \
    if [ "${ALLOCATOR}" = "mimalloc" ]; then \
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
            -DCMAKE_C_FLAGS="-march=${MARCH} -mtune=${MARCH} -frecord-gcc-switches"; \
        cmake --build /build/mimalloc/build; \
        test -s /build/mimalloc/build/mimalloc.o; \
        readelf -p .GCC.command.line /build/mimalloc/build/mimalloc.o | grep -qF -- "-march=${MARCH}"; \
    fi

# The script appends CFLAGS/CXXFLAGS/LDFLAGS from the environment to its own
# flags, so this is how the target is set for every module it builds (zlib,
# openssl, boost, Qt, libtorrent, qBittorrent). For the mimalloc variant the
# LDFLAGS also carry mimalloc.o, which the script appends at the end of the
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
    ldflags="-march=${MARCH}"; \
    if [ "${ALLOCATOR}" = "mimalloc" ]; then \
        ldflags="${ldflags} /build/mimalloc/build/mimalloc.o"; \
    fi; \
    export CFLAGS="-march=${MARCH} -mtune=${MARCH} -frecord-gcc-switches" \
           CXXFLAGS="-march=${MARCH} -mtune=${MARCH} -frecord-gcc-switches" \
           LDFLAGS="${ldflags}"; \
    if ! bash qbittorrent-nox-static.sh -lt "${LT_TAG}" -qt "${QBT_TAG}" -ot "${OPENSSL_TAG}" -cd /build/cache -n all > /build/build.log 2>&1; then \
        echo "=== build failed: tail -n 200 of /build/build.log ==="; \
        tail -n 200 /build/build.log; \
        for log in /build/qbt-build/logs/*.log; do \
            [ -f "${log}" ] || continue; \
            echo "=== ${log} (tail -n 100) ==="; \
            tail -n 100 "${log}"; \
        done; \
        exit 1; \
    fi; \
    tail -n 20 /build/build.log

# Fail the build unless the libtorrent patch really was applied, unless the
# patched source is what got compiled, unless qBittorrent was left unpatched,
# and unless the compiler was really invoked with the target flags. The script
# warns and carries on when a patch fails, so this step is the actual gate.
RUN set -eux; \
    bin=/build/qbt-build/completed/qbittorrent-nox; \
    test -x "${bin}"; \
    test "$(grep -c 'Patch applied successfully' /build/build.log)" -eq 1; \
    test "$(grep -c 'Applying:' /build/build.log)" -eq 1; \
    test "$(grep -c 'Using local patches method' /build/build.log)" -ge 2; \
    command -v ninja; \
    lt_src=$(echo /build/qbt-build/libtorrent-rasterbar-*/src); \
    qbt_src=$(echo /build/qbt-build/qBittorrent-*/src); \
    grep -qF 'SET(request_timeout, 20, nullptr)' "${lt_src}/settings_pack.cpp"; \
    grep -qF 'SET(whole_pieces_threshold, 10, nullptr)' "${lt_src}/settings_pack.cpp"; \
    grep -qF 'SET(max_peer_recv_buffer_size, 4 * 1024 * 1024, nullptr)' "${lt_src}/settings_pack.cpp"; \
    grep -qF 'SET(torrent_connect_boost, 50, nullptr)' "${lt_src}/settings_pack.cpp"; \
    grep -qF 'SET(predictive_piece_announce, 10, nullptr)' "${lt_src}/settings_pack.cpp"; \
    grep -qF 'SET(send_not_sent_low_watermark, 1024 * 1024, nullptr)' "${lt_src}/settings_pack.cpp"; \
    grep -qF -- "-march=${MARCH}" /build/qbt-build/libtorrent-rasterbar-*/build/CMakeCache.txt; \
    grep -qF -- "-march=${MARCH}" /build/qbt-build/qBittorrent-*/build/CMakeCache.txt; \
    ninja -C "$(echo /build/qbt-build/libtorrent-rasterbar-*/build)" -t commands > /build/ninja-libtorrent.txt; \
    awk -v m="-march=${MARCH}" 'index($0, "settings_pack.cpp.o") && index($0, m) { found = 1 } END { exit !found }' /build/ninja-libtorrent.txt; \
    ninja -C "$(echo /build/qbt-build/qBittorrent-*/build)" -t commands > /build/ninja-qbittorrent.txt; \
    awk -v m="-march=${MARCH}" 'index($0, "sessionimpl.cpp.o") && index($0, m) { found = 1 } END { exit !found }' /build/ninja-qbittorrent.txt; \
    "${bin}" --version > /build/version.txt; \
    grep -qF "v${QBT_VERSION}" /build/version.txt; \
    if [ "${ALLOCATOR}" = "mimalloc" ]; then \
        grep -qF 'mimalloc' "${bin}"; \
        readelf -p .GCC.command.line "${bin}" | grep -qF -- "-march=${MARCH}"; \
    fi

# Provenance for the runtime image: what was built, with which target, the
# allocator, and the exact patch consumed from this repository.
RUN set -eux; \
    { \
        echo "qbittorrent=${QBT_VERSION}"; \
        echo "qbittorrent_patches=none"; \
        echo "libtorrent=${LT_VERSION}"; \
        echo "march=${MARCH}"; \
        echo "build_jobs=${BUILD_JOBS}"; \
        echo "allocator=${ALLOCATOR}"; \
        echo "libtorrent_patch_sha256=$(sha256sum "/build/patches/libtorrent/${LT_VERSION}/patch" | cut -d' ' -f1)"; \
        echo "build_script_sha256=${QBT_STATIC_SCRIPT_SHA256}"; \
        if [ "${ALLOCATOR}" = "mimalloc" ]; then \
            echo "mimalloc_tag=${MIMALLOC_TAG}"; \
            echo "mimalloc_sha256=${MIMALLOC_SHA256}"; \
        fi; \
    } > /build/BUILD-INFO; \
    cat /build/BUILD-INFO

###############################################################################
# runtime
###############################################################################
FROM ${UNRAR_IMAGE} AS unrar

FROM ${ALPINE_IMAGE} AS runtime

ARG QBT_VERSION
ARG LT_VERSION
ARG MARCH=znver3
ARG ALLOCATOR=musl

LABEL org.opencontainers.image.source="https://github.com/swizzin/qbittorrent" \
      org.opencontainers.image.licenses="Apache-2.0 AND GPL-2.0-or-later" \
      org.opencontainers.image.version="${QBT_VERSION}" \
      org.opencontainers.image.description="qBittorrent ${QBT_VERSION} on libtorrent ${LT_VERSION}, static musl, 10g libtorrent defaults, compiled for ${MARCH}, ${ALLOCATOR} malloc"

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
