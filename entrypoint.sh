#!/usr/bin/env bash
# Container entrypoint: prepare /config, then exec qbittorrent-nox.
#
# Everything written here lives under $XDG_CONFIG_HOME (which is also
# $XDG_DATA_HOME and $HOME, i.e. /config), so the image runs with a read-only
# root filesystem. qBittorrent's own configuration is not seeded: the file at
# /config/qBittorrent/qBittorrent.conf is created by qBittorrent on first run
# and owned by whatever provisions the volume.

set -euo pipefail

config_root="${XDG_CONFIG_HOME:-/config}"
app_dir="${config_root}/qBittorrent"

mkdir -p "${app_dir}/logs"

# Send the log to the container's stdout instead of a file inside the volume,
# unless something already occupies that path.
if [[ ! -e "${app_dir}/logs/qbittorrent.log" && ! -L "${app_dir}/logs/qbittorrent.log" ]]; then
    ln -s /proc/self/fd/1 "${app_dir}/logs/qbittorrent.log"
fi

# A lockfile left behind by a killed container makes qbittorrent-nox refuse to
# start. This container is single-instance by construction, so any lockfile
# present before we start is stale.
rm -f "${app_dir}/lockfile"

exec /app/qbittorrent-nox "$@"
