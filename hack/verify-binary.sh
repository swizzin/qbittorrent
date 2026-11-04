#!/usr/bin/env bash
# Verify a built qbittorrent image.
#
#   hack/verify-binary.sh <image>
#
# Checks the binary itself (version strings, no profiling/allocator artefacts,
# the actual microarchitecture it was compiled for, static linkage), the
# provenance file, and the image configuration this repository promises.
# Exits non-zero on any failure and prints PASS at the end.

set -euo pipefail

image="${1:-}"
if [[ -z ${image} ]]; then
    printf 'usage: %s <image>\n' "${0##*/}" >&2
    exit 2
fi

for tool in docker readelf objdump file grep; do
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

printf 'image: %s\n\n' "${image}"

# --------------------------------------------------------------------------
# version strings
# --------------------------------------------------------------------------
version_output=$(docker run --rm --entrypoint /app/qbittorrent-nox "${image}" --version)
printf 'binary says: %s\n' "${version_output}"
if grep -Eq "qBittorrent v?${qbt_re}([^0-9.]|\$)" <<<"${version_output}"; then
    ok "qbittorrent-nox --version reports v${QBT_VERSION}"
else
    bad "qbittorrent-nox --version reports v${QBT_VERSION} (got: ${version_output})"
fi

lt_versions=$(grep -ao 'libtorrent/[0-9][0-9.]*' "${bin}" | sort -u || true)
if [[ ${lt_versions} == "libtorrent/${LT_VERSION}" || ${lt_versions} == "libtorrent/${LT_VERSION}.0" ]]; then
    ok "binary carries libtorrent ${LT_VERSION} (${lt_versions})"
else
    bad "binary carries libtorrent ${LT_VERSION} (found: ${lt_versions:-nothing})"
fi

# --------------------------------------------------------------------------
# no instrumentation, no allocator
# --------------------------------------------------------------------------
if hits=$(grep -aoE '__gcov|fprofile|tcmalloc|MallocExtension|mi_malloc' "${bin}" | sort -u) && [[ -n ${hits} ]]; then
    bad "binary is free of profiling/allocator artefacts (found: $(tr '\n' ' ' <<<"${hits}"))"
else
    ok "binary is free of gcov/fprofile/tcmalloc/mimalloc artefacts"
fi

# --------------------------------------------------------------------------
# microarchitecture
#
# -frecord-gcc-switches records the compiler flags in .GCC.command.line, which
# survives -s and LTO, so the exact -march value can be read back out of the
# stripped binary. The instruction census then shows the flag was not inert:
# BMI2 (shlx/shrx/sarx/mulx/rorx) and ymm (VEX/AVX) instructions do not exist
# on baseline x86-64.
# --------------------------------------------------------------------------
if readelf -p .GCC.command.line "${bin}" 2>/dev/null | grep -qF -- "-march=${MARCH}"; then
    ok "compiler flags recorded in the binary contain -march=${MARCH}"
    readelf -p .GCC.command.line "${bin}" | grep -oF -- "-march=${MARCH}" | head -n1 | sed 's/^/      /'
else
    bad "compiler flags recorded in the binary contain -march=${MARCH}"
fi

objdump -d --no-show-raw-insn "${bin}" >"${tmpdir}/disasm.txt"
bmi2=$(grep -cE '[[:space:]](shlx|shrx|sarx|mulx|rorx)([[:space:]]|$)' "${tmpdir}/disasm.txt" || true)
avx=$(grep -c 'ymm' "${tmpdir}/disasm.txt" || true)
printf '      instruction census: BMI2=%s ymm=%s\n' "${bmi2}" "${avx}"
if ((bmi2 > 0)); then
    ok "compiled code contains BMI2 instructions"
else
    bad "compiled code contains BMI2 instructions"
fi
if ((avx > 0)); then
    ok "compiled code contains AVX (ymm) instructions"
else
    bad "compiled code contains AVX (ymm) instructions"
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
lt_patch_sha=$(sha256sum "${repo_root}/patches/libtorrent/${LT_VERSION}/patch" | cut -d' ' -f1)
expect "BUILD-INFO records this repo's libtorrent patch" \
    grep -qx "libtorrent_patch_sha256=${lt_patch_sha}" "${tmpdir}/BUILD-INFO"
expect "BUILD-INFO records that qBittorrent has no patches" \
    grep -qx 'qbittorrent_patches=none' "${tmpdir}/BUILD-INFO"
expect "BUILD-INFO records march=${MARCH}" \
    grep -qx "march=${MARCH}" "${tmpdir}/BUILD-INFO"
expect "BUILD-INFO records libtorrent=${LT_VERSION}" \
    grep -qx "libtorrent=${LT_VERSION}" "${tmpdir}/BUILD-INFO"

# --------------------------------------------------------------------------
# image layout and configuration
# --------------------------------------------------------------------------
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
check_label org.opencontainers.image.licenses 'Apache-2.0 AND GPL-2.0-or-later'
check_label org.opencontainers.image.version "${QBT_VERSION}"

unwanted=$(docker run --rm --entrypoint /bin/sh "${image}" -c 'command -v python3 curl jq vim 2>/dev/null || true')
if [[ -z ${unwanted} ]]; then
    ok "no python/curl/jq/vim in the image"
else
    bad "no python/curl/jq/vim in the image (found: $(tr '\n' ' ' <<<"${unwanted}"))"
fi

printf '\n'
if ((failures > 0)); then
    printf '%d check(s) failed\n' "${failures}" >&2
    exit 1
fi
printf 'PASS\n'
