#!/usr/bin/env bash
# Print the versions the Dockerfile builds, as shell assignments:
#
#   eval "$(hack/versions.sh)"   # sets QBT_VERSION, LT_VERSION, MARCH, IMAGE_TAG
#
# The Dockerfile is the single source of truth; the checks and CI read it from
# here so a version bump is one line.

set -euo pipefail

dockerfile="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/Dockerfile"

arg() {
    local value
    value=$(sed -nE "s/^ARG ${1}=([^[:space:]]+)\$/\\1/p" "${dockerfile}" | head -n1)
    [[ -n ${value} ]] || { printf 'versions: ARG %s not found in Dockerfile\n' "${1}" >&2; exit 1; }
    printf '%s' "${value}"
}

qbt=$(arg QBT_VERSION)
lt=$(arg LT_VERSION)
march=$(arg MARCH)

printf 'QBT_VERSION=%q\n' "${qbt}"
printf 'LT_VERSION=%q\n' "${lt}"
printf 'MARCH=%q\n' "${march}"
printf 'IMAGE_TAG=%q\n' "${qbt}-lt${lt}-10g-${march}"
