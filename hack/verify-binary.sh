#!/usr/bin/env bash
# Verify a built qbittorrent image.
#
#   hack/verify-binary.sh <image>
#
# Checks the binary itself (version strings, no profiling/allocator artefacts,
# the actual architecture and microarchitecture it was compiled for, static
# linkage), the provenance file, and the image configuration this repository
# promises. Exits non-zero on any failure and prints PASS at the end.
#
# The image identifies its own build axes through /app/BUILD-INFO (profile,
# arch, march, allocator, libtorrent line). The binary is executed, so verify an
# image on a host of its own architecture (as CI does); for a foreign-arch image
# on a host without qemu binfmt, set QBT_VERIFY_RUN=0 to fall back to static
# inspection.

set -euo pipefail

image="${1:-}"
if [[ -z ${image} ]]; then
    printf 'usage: %s <image>\n' "${0##*/}" >&2
    exit 2
fi

for tool in docker readelf objdump file grep strings; do
    command -v "${tool}" >/dev/null 2>&1 || {
        printf 'verify-binary: host tool not found: %s\n' "${tool}" >&2
        exit 2
    }
done

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
eval "$("${repo_root}/hack/versions.sh")"
qbt_re=${QBT_VERSION//./\\.}

tmpdir=$(mktemp -d)
container="qbt-verify-$$"
cleanup() {
    docker rm -f "${container}" >/dev/null 2>&1 || true
    rm -rf "${tmpdir}"
}
trap cleanup EXIT

failures=0
ok() { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*" >&2; failures=$((failures + 1)); }
skip() { printf 'skip  %s\n' "$*"; }

# expect <description> <command...>
expect() {
    local desc="${1}"
    shift
    if "$@"; then ok "${desc}"; else bad "${desc}"; fi
}

docker image inspect "${image}" >/dev/null 2>&1 || {
    printf 'verify-binary: image not found: %s\n' "${image}" >&2
    exit 2
}

docker create --name "${container}" "${image}" >/dev/null
docker cp "${container}:/app/qbittorrent-nox" "${tmpdir}/qbittorrent-nox" >/dev/null
docker cp "${container}:/app/BUILD-INFO" "${tmpdir}/BUILD-INFO" >/dev/null
bin="${tmpdir}/qbittorrent-nox"

# The image identifies its own build axes through BUILD-INFO. march and arch
# default to the values an image from before those fields carried, and the
# libtorrent line is read from BUILD-INFO too: two lines are built, each with
# its own patch pair, so the image itself says which one it was built on. The
# `allocator` field predates all of them and defaults to musl; an image that
# predates the fields the pairing check below needs is a frozen pre-scheme
# image, and the check refuses it rather than guessing which malloc it links.
allocator=$(sed -n 's/^allocator=//p' "${tmpdir}/BUILD-INFO")
allocator="${allocator:-musl}"
profile=$(sed -n 's/^profile=//p' "${tmpdir}/BUILD-INFO")
profile="${profile:-10g}"
arch=$(sed -n 's/^arch=//p' "${tmpdir}/BUILD-INFO")
arch="${arch:-amd64}"
march=$(sed -n 's/^march=//p' "${tmpdir}/BUILD-INFO")
march="${march:-znver3}"
lt=$(sed -n 's/^libtorrent=//p' "${tmpdir}/BUILD-INFO")
lt="${lt:-${LT_VERSION}}"
case "${allocator}" in
    musl|mimalloc) ;;
    *) printf 'verify-binary: unknown allocator %q in BUILD-INFO\n' "${allocator}" >&2; exit 2 ;;
esac
case "${profile}" in
    base|10g) ;;
    *) printf 'verify-binary: unknown profile %q in BUILD-INFO\n' "${profile}" >&2; exit 2 ;;
esac
# The allocator follows the profile: base is musl, 10g is mimalloc, on every
# libtorrent line and every architecture. The Dockerfile and hack/versions.sh
# both refuse any other pairing, so an image claiming one is describing a build
# this repository cannot make.
case "${profile}:${allocator}" in
    base:musl|10g:mimalloc) ;;
    *)
        printf 'verify-binary: BUILD-INFO pairs profile %s with allocator %s, but base links musl and 10g links mimalloc\n' \
            "${profile}" "${allocator}" >&2
        exit 2
        ;;
esac
printf 'profile: %s  arch: %s  march: %s  allocator: %s  libtorrent: %s\n\n' \
    "${profile}" "${arch}" "${march}" "${allocator}" "${lt}"

# Whether the binary can be executed here. amd64 runs natively; arm64 needs
# qemu binfmt on this host. QBT_VERIFY_RUN=0 forces static-only checks.
can_run=1
if [[ ${arch} == "arm64" && ${QBT_VERIFY_RUN:-1} == 0 ]]; then
    can_run=0
fi

printf 'image: %s\n\n' "${image}"

# --------------------------------------------------------------------------
# version strings
# --------------------------------------------------------------------------
if [[ ${can_run} == 1 ]]; then
    version_output=$(docker run --rm --entrypoint /app/qbittorrent-nox "${image}" --version 2>/dev/null || true)
else
    version_output=$(strings "${bin}" | grep -aoE 'qBittorrent v?[0-9]+(\.[0-9]+)+' | head -n1 || true)
fi
printf 'binary says: %s\n' "${version_output}"
if grep -Eq "qBittorrent v?${qbt_re}([^0-9.]|$)" <<<"${version_output}"; then
    ok "qbittorrent-nox --version reports v${QBT_VERSION}"
else
    bad "qbittorrent-nox --version reports v${QBT_VERSION} (got: ${version_output})"
fi

lt_versions=$(grep -ao 'libtorrent/[0-9][0-9.]*' "${bin}" | sort -u || true)
if [[ ${lt_versions} == "libtorrent/${lt}" || ${lt_versions} == "libtorrent/${lt}.0" ]]; then
    ok "binary carries libtorrent ${lt} (${lt_versions})"
else
    bad "binary carries libtorrent ${lt} (found: ${lt_versions:-nothing})"
fi

# --------------------------------------------------------------------------
# no instrumentation; allocator
# --------------------------------------------------------------------------
if hits=$(grep -aoE '__gcov|fprofile|tcmalloc|MallocExtension' "${bin}" | sort -u) && [[ -n ${hits} ]]; then
    bad "binary is free of profiling/tcmalloc artefacts (found: $(tr '\n' ' ' <<<"${hits}"))"
else
    ok "binary is free of gcov/fprofile/tcmalloc artefacts"
fi

if [[ ${allocator} == "mimalloc" ]]; then
    # Static presence alone is not enough: prove mimalloc is the live allocator
    # at runtime. MIMALLOC_VERBOSE/SHOW_STATS are set only for this check, so
    # the runtime image keeps mimalloc's default behaviour.
    if grep -aq 'mimalloc' "${bin}"; then
        ok "mimalloc is compiled into the binary"
    else
        bad "mimalloc is compiled into the binary"
    fi

    verbose_out=$(docker run --rm -e MIMALLOC_VERBOSE=1 --entrypoint /app/qbittorrent-nox "${image}" --version 2>&1 || true)
    if grep -q 'mimalloc: process init' <<<"${verbose_out}"; then
        ok "MIMALLOC_VERBOSE=1 proves mimalloc is the live allocator"
    else
        bad "MIMALLOC_VERBOSE=1 proves mimalloc is the live allocator (got: $(head -c 300 <<<"${verbose_out}"))"
    fi
else
    if grep -aq 'mimalloc' "${bin}"; then
        bad "musl variant is free of mimalloc artefacts"
    else
        ok "musl variant is free of mimalloc artefacts"
    fi
fi

# --------------------------------------------------------------------------
# architecture and microarchitecture
#
# -frecord-gcc-switches records the compiler flags in .GCC.command.line, which
# survives -s and LTO, so the exact -march value can be read back out of the
# stripped binary. The ELF machine field asserts the architecture.
#
# For znver3 an instruction census then shows the -march flag was not inert:
# the compiled code contains BMI2 (shlx/shrx/sarx/mulx/rorx) and ymm (VEX/AVX)
# instructions. For the baseline the census cannot say the opposite: OpenSSL's
# hand-written assembly carries BMI2 and AVX2 paths that it selects at run time
# from cpuid, so they are in every amd64 binary and run only on a CPU that has
# them. What the baseline promises is that the compiler was never told it may
# use them, so that is what is checked: every -march recorded in the binary is
# x86-64 or x86-64-v2, and no recorded switch enables an extension beyond it.
# --------------------------------------------------------------------------
machine=$(readelf -h "${bin}" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')
printf '      ELF machine: %s\n' "${machine}"
if [[ ${arch} == "amd64" ]] && grep -q 'X86-64' <<<"${machine}"; then
    ok "ELF machine is x86-64"
elif [[ ${arch} == "arm64" ]] && grep -qi 'aarch64' <<<"${machine}"; then
    ok "ELF machine is AArch64"
else
    bad "ELF machine matches arch=${arch} (got: ${machine})"
fi

if readelf -p .GCC.command.line "${bin}" 2>/dev/null | grep -qF -- "-march=${march}"; then
    ok "compiler flags recorded in the binary contain -march=${march}"
    readelf -p .GCC.command.line "${bin}" | grep -oF -- "-march=${march}" | head -n1 | sed 's/^/      /'
else
    bad "compiler flags recorded in the binary contain -march=${march}"
fi

if [[ ${arch} == "arm64" ]]; then
    ok "arm64 binary carries no x86 BMI2/AVX instructions (AArch64)"
else
    objdump -d --no-show-raw-insn "${bin}" >"${tmpdir}/disasm.txt"
    bmi2=$(grep -cE '[[:space:]](shlx|shrx|sarx|mulx|rorx)([[:space:]]|$)' "${tmpdir}/disasm.txt" || true)
    avx=$(grep -c 'ymm' "${tmpdir}/disasm.txt" || true)
    printf '      instruction census: BMI2=%s ymm=%s\n' "${bmi2}" "${avx}"
    if [[ ${march} == "znver3" ]]; then
        if ((bmi2 > 0)); then ok "compiled code contains BMI2 instructions"; else bad "compiled code contains BMI2 instructions"; fi
        if ((avx > 0)); then ok "compiled code contains AVX (ymm) instructions"; else bad "compiled code contains AVX (ymm) instructions"; fi
    else
        readelf -p .GCC.command.line "${bin}" >"${tmpdir}/switches.txt" 2>/dev/null || true
        marches=$(grep -oE -- '-march=[^[:space:]]+' "${tmpdir}/switches.txt" | sort -u | tr '\n' ' ')
        printf '      recorded -march values: %s\n' "${marches:-none}"
        above=""
        for m in ${marches}; do
            case "${m}" in
                -march=x86-64 | -march=x86-64-v2) ;;
                *) above="${above} ${m}" ;;
            esac
        done
        if [[ -n ${marches} && -z ${above} ]]; then
            ok "every recorded -march is at most x86-64-v2"
        else
            bad "every recorded -march is at most x86-64-v2 (found:${above:- none recorded})"
        fi
        extensions=$(grep -oE -- '-m(avx[0-9a-z]*|bmi2?|fma|f16c|lzcnt|movbe|adx|sha|vaes|vpclmulqdq|gfni)([[:space:]]|$)' "${tmpdir}/switches.txt" | sort -u | tr -d '\n' || true)
        if [[ -z ${extensions} ]]; then
            ok "no recorded switch enables an extension beyond x86-64-v2"
        else
            bad "no recorded switch enables an extension beyond x86-64-v2 (found: ${extensions})"
        fi
    fi
fi

# --------------------------------------------------------------------------
# static linkage
# --------------------------------------------------------------------------
if file "${bin}" | grep -Eq 'statically linked|static-pie linked'; then
    ok "binary is statically linked"
else
    bad "binary is statically linked ($(file -b "${bin}"))"
fi

# --------------------------------------------------------------------------
# provenance: the patches in this repository are the patches that were built
# --------------------------------------------------------------------------
case "${profile}" in
    base) patch_file="${repo_root}/patches/libtorrent/${lt}/base.patch" ;;
    10g) patch_file="${repo_root}/patches/libtorrent/${lt}/patch" ;;
esac
if [[ ! -f ${patch_file} ]]; then
    printf 'verify-binary: no patch pair for libtorrent %s in this repository (%s)\n' \
        "${lt}" "${patch_file}" >&2
    exit 2
fi
lt_patch_sha=$(sha256sum "${patch_file}" | cut -d' ' -f1)
expect "BUILD-INFO records this repo's libtorrent patch" \
    grep -qx "libtorrent_patch_sha256=${lt_patch_sha}" "${tmpdir}/BUILD-INFO"
expect "BUILD-INFO records that qBittorrent has no patches" \
    grep -qx 'qbittorrent_patches=none' "${tmpdir}/BUILD-INFO"
expect "BUILD-INFO records profile=${profile}" \
    grep -qx "profile=${profile}" "${tmpdir}/BUILD-INFO"
expect "BUILD-INFO records arch=${arch}" \
    grep -qx "arch=${arch}" "${tmpdir}/BUILD-INFO"
expect "BUILD-INFO records march=${march}" \
    grep -qx "march=${march}" "${tmpdir}/BUILD-INFO"
expect "BUILD-INFO records libtorrent=${lt}" \
    grep -qx "libtorrent=${lt}" "${tmpdir}/BUILD-INFO"
expect "BUILD-INFO records allocator=${allocator}" \
    grep -qx "allocator=${allocator}" "${tmpdir}/BUILD-INFO"
if [[ ${allocator} == "mimalloc" ]]; then
    expect "BUILD-INFO records mimalloc tag ${MIMALLOC_TAG}" \
        grep -qx "mimalloc_tag=${MIMALLOC_TAG}" "${tmpdir}/BUILD-INFO"
    expect "BUILD-INFO records the mimalloc tarball sha256" \
        grep -qx "mimalloc_sha256=${MIMALLOC_SHA256}" "${tmpdir}/BUILD-INFO"
    # Statistics and sampled profiling are compiled out (the Dockerfile checks
    # mimalloc's configure output; BUILD-INFO records that it did).
    expect "BUILD-INFO records mimalloc statistics off" \
        grep -qx "mimalloc_stats=off" "${tmpdir}/BUILD-INFO"
    expect "BUILD-INFO records mimalloc profiling off" \
        grep -qx "mimalloc_profile=off" "${tmpdir}/BUILD-INFO"
fi

# --------------------------------------------------------------------------
# image layout and configuration (runs the image's shell, so amd64 / qemu only)
# --------------------------------------------------------------------------
if [[ ${can_run} == 1 ]]; then
    layout=$(docker run --rm --entrypoint /bin/sh "${image}" -c '
        printf "%s %s\n" "$(stat -c "%u:%g %a" /app/qbittorrent-nox)" "$(test -x /app/qbittorrent-nox && echo x)"
        printf "unrar %s %s\n" "$(stat -c "%a" /usr/bin/unrar)" "$(test -x /usr/bin/unrar && echo x)"
        printf "qbt-unpack %s %s\n" "$(stat -c "%a" /usr/local/bin/qbt-unpack)" "$(test -x /usr/local/bin/qbt-unpack && echo x)"
        printf "entrypoint %s\n" "$(test -x /entrypoint.sh && echo x)"
        printf "seeded-config %s\n" "$(test -e /config/qBittorrent/qBittorrent.conf && echo yes || echo no)"
    ')
    grep -qx '0:0 755 x' <<<"${layout}" \
        && ok "/app/qbittorrent-nox is root-owned, mode 0755, executable" \
        || bad "/app/qbittorrent-nox is root-owned, mode 0755, executable"
    grep -qx 'unrar 755 x' <<<"${layout}" \
        && ok "/usr/bin/unrar is mode 0755" \
        || bad "/usr/bin/unrar is mode 0755"
    grep -qx 'qbt-unpack 755 x' <<<"${layout}" \
        && ok "/usr/local/bin/qbt-unpack is mode 0755" \
        || bad "/usr/local/bin/qbt-unpack is mode 0755"
    grep -qx 'entrypoint x' <<<"${layout}" \
        && ok "/entrypoint.sh is executable" \
        || bad "/entrypoint.sh is executable"
    grep -qx 'seeded-config no' <<<"${layout}" \
        && ok "no qBittorrent.conf is baked into the image" \
        || bad "no qBittorrent.conf is baked into the image"
else
    skip "image layout checks (foreign-arch binary cannot run without qemu)"
fi

cfg_user=$(docker image inspect -f '{{.Config.User}}' "${image}")
[[ ${cfg_user} == '65534:65534' ]] \
    && ok "image user is 65534:65534" \
    || bad "image user is 65534:65534 (got: ${cfg_user})"

entrypoint=$(docker image inspect -f '{{json .Config.Entrypoint}}' "${image}")
[[ ${entrypoint} == '["/usr/bin/catatonit","--","/entrypoint.sh"]' ]] \
    && ok "entrypoint is catatonit -> /entrypoint.sh" \
    || bad "entrypoint is catatonit -> /entrypoint.sh (got: ${entrypoint})"

env_dump=$(docker image inspect -f '{{json .Config.Env}}' "${image}")
for want in 'QBT_CONFIRM_LEGAL_NOTICE=1' 'HOME=/config' 'XDG_CONFIG_HOME=/config' 'XDG_DATA_HOME=/config'; do
    if grep -qF "\"${want}\"" <<<"${env_dump}"; then
        ok "env ${want}"
    else
        bad "env ${want}"
    fi
done

exposed=$(docker image inspect -f '{{json .Config.ExposedPorts}}' "${image}")
[[ ${exposed} == '{"8080/tcp":{}}' ]] \
    && ok "exposes 8080/tcp" \
    || bad "exposes 8080/tcp (got: ${exposed})"

labels=$(docker image inspect -f '{{json .Config.Labels}}' "${image}")
check_label() {
    local key="${1}" value="${2}"
    if grep -qF "\"${key}\":\"${value}\"" <<<"${labels}"; then
        ok "label ${key}=${value}"
    else
        bad "label ${key}=${value}"
    fi
}
check_label org.opencontainers.image.source https://github.com/swizzin/qbittorrent
check_label org.opencontainers.image.licenses 'Apache-2.0 AND GPL-3.0-or-later'
check_label org.opencontainers.image.version "${QBT_VERSION}"

# The OCI description records which allocator the image carries.
description=$(docker image inspect -f '{{json .Config.Labels}}' "${image}" \
    | sed -n 's/.*"org.opencontainers.image.description":"\([^"]*\)".*/\1/p')
if grep -qF "${allocator}" <<<"${description}"; then
    ok "OCI description mentions the ${allocator} allocator"
else
    bad "OCI description mentions the ${allocator} allocator (got: ${description})"
fi

if [[ ${can_run} == 1 ]]; then
    unwanted=$(docker run --rm --entrypoint /bin/sh "${image}" -c 'command -v python3 curl jq vim 2>/dev/null || true')
    if [[ -z ${unwanted} ]]; then
        ok "no python/curl/jq/vim in the image"
    else
        bad "no python/curl/jq/vim in the image (found: $(tr '\n' ' ' <<<"${unwanted}"))"
    fi
else
    skip "unwanted-tool check (foreign-arch binary cannot run without qemu)"
fi

printf '\n'
if ((failures > 0)); then
    printf '%d check(s) failed\n' "${failures}" >&2
    exit 1
fi
printf 'PASS\n'
