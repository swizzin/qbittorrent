#!/usr/bin/env bash
# Smoke test a built qbittorrent image.
#
#   hack/smoke.sh <image>
#
# Runs the image the way a consumer does: read-only root filesystem, a
# non-root uid that is not the image's default user, tmpfs /tmp, an empty
# /config, and QBT_WEBUI_PORT set through the environment. Then talks to the
# WebUI API over loopback from inside the container, using the temporary
# password qBittorrent prints on first start, and checks the bundled tools.
# Prints PASS at the end.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
eval "$("${repo_root}/hack/versions.sh")"
qbt_re=${QBT_VERSION//./\\.}
lt_re=${LT_VERSION//./\\.}

image="${1:-}"
if [[ -z ${image} ]]; then
    printf 'usage: %s <image>\n' "${0##*/}" >&2
    exit 2
fi

webui_port=8099
name="qbt-smoke-$$"
cfg=$(mktemp -d)
chmod 0777 "${cfg}"

cleanup() {
    docker rm -f "${name}" >/dev/null 2>&1 || true
    # Files in /config are owned by the container uid, which is not the host
    # user, so remove them from a container that runs as root.
    docker run --rm --user 0 -v "${cfg}:/cfg" --entrypoint /bin/sh "${image}" \
        -c 'find /cfg -mindepth 1 -delete' >/dev/null 2>&1 || true
    rmdir "${cfg}" 2>/dev/null || true
}
trap cleanup EXIT

failures=0
ok() { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*" >&2; failures=$((failures + 1)); }

printf 'image: %s\n\n' "${image}"

docker run -d --name "${name}" \
    --read-only \
    --user 1000:1000 \
    --tmpfs /tmp:rw,size=64m,mode=1777 \
    -v "${cfg}:/config" \
    -e QBT_WEBUI_PORT="${webui_port}" \
    -e QBT_TORRENTING_PORT=6881 \
    "${image}" >/dev/null

# --------------------------------------------------------------------------
# wait for the WebUI
# --------------------------------------------------------------------------
ready=0
for _ in $(seq 1 120); do
    if docker exec "${name}" wget -q -O /dev/null "http://127.0.0.1:${webui_port}/" 2>/dev/null; then
        ready=1
        break
    fi
    if [[ $(docker inspect -f '{{.State.Running}}' "${name}") != 'true' ]]; then
        break
    fi
    sleep 1
done
if ((ready == 1)); then
    ok "WebUI answered on 127.0.0.1:${webui_port} (QBT_WEBUI_PORT honoured)"
else
    bad "WebUI answered on 127.0.0.1:${webui_port} (QBT_WEBUI_PORT honoured)"
    printf '\n--- container logs ---\n' >&2
    docker logs "${name}" >&2 || true
    printf '\n%d check(s) failed\n' $((failures + 1)) >&2
    exit 1
fi

# --------------------------------------------------------------------------
# authenticate with the temporary password from the first-start log
# --------------------------------------------------------------------------
password=$(docker logs "${name}" 2>&1 \
    | sed -n 's/.*temporary password is provided for this session: //p' \
    | tail -n1 | tr -d '\r[:space:]')
if [[ -n ${password} ]]; then
    ok "qBittorrent printed a temporary WebUI password"
else
    bad "qBittorrent printed a temporary WebUI password"
    docker logs "${name}" >&2 || true
    exit 1
fi

login=$(docker exec "${name}" wget -S -O /dev/null \
    --header="Referer: http://127.0.0.1:${webui_port}" \
    --post-data="username=admin&password=${password}" \
    "http://127.0.0.1:${webui_port}/api/v2/auth/login" 2>&1 || true)
# qBittorrent 5.x names the session cookie after the WebUI port and answers a
# successful login with 204.
sid=$(grep -o 'QBT_SID_[0-9]*=[^;[:space:]]*' <<<"${login}" | head -n1 || true)
if [[ -n ${sid} ]]; then
    ok "logged in to the WebUI API (${sid%%=*}=<redacted>)"
else
    bad "logged in to the WebUI API"
    printf '%s\n' "${login}" >&2
    exit 1
fi

api() {
    docker exec "${name}" wget -q -O - \
        --header="Cookie: ${sid}" \
        "http://127.0.0.1:${webui_port}${1}"
}

api_version=$(api /api/v2/app/version)
printf 'API /app/version: %s\n' "${api_version}"
if grep -Eq "^v?${qbt_re}$" <<<"${api_version}"; then
    ok "API reports qBittorrent ${QBT_VERSION}"
else
    bad "API reports qBittorrent ${QBT_VERSION} (got: ${api_version})"
fi

build_info=$(api /api/v2/app/buildInfo)
printf 'API /app/buildInfo: %s\n' "${build_info}"
if grep -Eq "\"libtorrent\":\"${lt_re}(\\.[0-9]+)?\"" <<<"${build_info}"; then
    ok "API reports libtorrent ${LT_VERSION}"
else
    bad "API reports libtorrent ${LT_VERSION} (got: ${build_info})"
fi

# --------------------------------------------------------------------------
# process
# --------------------------------------------------------------------------
comm=$(docker exec "${name}" cat /proc/1/comm)
[[ ${comm} == 'catatonit' ]] \
    && ok "pid 1 is catatonit" \
    || bad "pid 1 is catatonit (got: ${comm})"

owners=$(docker exec "${name}" sh -c '
    for p in /proc/[0-9]*; do
        [ -r "${p}/cmdline" ] || continue
        tr "\0" " " < "${p}/cmdline" 2>/dev/null | grep -q qbittorrent-nox || continue
        awk "/^Uid:/{print \$2}" "${p}/status"
    done' | sort -u)
if [[ ${owners} == '1000' ]]; then
    ok "qbittorrent-nox runs as uid 1000"
else
    bad "qbittorrent-nox runs as uid 1000 (got: ${owners:-nothing})"
fi

# --------------------------------------------------------------------------
# filesystem
# --------------------------------------------------------------------------
ro=$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "${name}")
[[ ${ro} == 'true' ]] \
    && ok "root filesystem is read-only" \
    || bad "root filesystem is read-only (got: ${ro})"

if docker exec "${name}" touch /qbittorrent-smoke-probe >/dev/null 2>&1; then
    bad "writing outside /config and /tmp is refused"
else
    ok "writing outside /config and /tmp is refused"
fi

top_level=$(find "${cfg}" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
unexpected=$(grep -vE '^(qBittorrent|\.cache)$' <<<"${top_level}" || true)
if [[ -z ${unexpected} ]]; then
    ok "/config contains only qBittorrent/ (and Qt's .cache)"
else
    bad "/config contains only qBittorrent/ (found: $(tr '\n' ' ' <<<"${unexpected}"))"
fi

log_target=$(docker exec "${name}" readlink /config/qBittorrent/logs/qbittorrent.log || true)
[[ ${log_target} == '/proc/self/fd/1' ]] \
    && ok "qbittorrent.log is symlinked to container stdout" \
    || bad "qbittorrent.log is symlinked to container stdout (got: ${log_target:-nothing})"

[[ -e ${cfg}/qBittorrent/lockfile ]] \
    && ok "qBittorrent wrote its lockfile under /config" \
    || bad "qBittorrent wrote its lockfile under /config"

# --------------------------------------------------------------------------
# bundled tools
# --------------------------------------------------------------------------
unrar_out=$(docker exec "${name}" unrar 2>&1 | grep -m1 'UNRAR' || true)
grep -q 'UNRAR' <<<"${unrar_out}" \
    && ok "unrar runs (${unrar_out})" \
    || bad "unrar runs (got: ${unrar_out})"

seven_out=$(docker exec "${name}" 7zz 2>&1 | grep -m1 '7-Zip' || true)
grep -q '7-Zip' <<<"${seven_out}" \
    && ok "7zz runs (${seven_out})" \
    || bad "7zz runs (got: ${seven_out})"

unzip_out=$(docker exec "${name}" unzip 2>&1 | head -n3 | tr '\n' ' ' || true)
grep -qi 'unzip' <<<"${unzip_out}" \
    && ok "unzip runs (busybox applet)" \
    || bad "unzip runs (got: ${unzip_out})"

if docker exec "${name}" bash -c '
    set -euo pipefail
    work=$(mktemp -d)
    cd "${work}"
    printf "payload\n" > inside.txt
    7zz a -bd -bso0 -bsp0 archive.zip inside.txt >/dev/null
    mkdir -p payload
    mv archive.zip payload/
    qbt-unpack "${work}/payload" >/dev/null 2>&1
    test -f "${work}/payload/inside.txt"
' >/dev/null 2>&1; then
    ok "qbt-unpack extracts a zip into the torrent directory"
else
    bad "qbt-unpack extracts a zip into the torrent directory"
fi

# --------------------------------------------------------------------------
# still alive
# --------------------------------------------------------------------------
sleep 2
if [[ $(docker inspect -f '{{.State.Running}}' "${name}") == 'true' ]]; then
    ok "container is still running"
else
    bad "container is still running"
    docker logs "${name}" >&2 || true
fi

printf '\n'
if ((failures > 0)); then
    printf '%d check(s) failed\n' "${failures}" >&2
    printf '\n--- container logs ---\n' >&2
    docker logs "${name}" >&2 || true
    exit 1
fi
printf 'PASS\n'
