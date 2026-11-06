#!/usr/bin/env bash
# Print the versions the Dockerfile builds, as shell assignments:
#
#   eval "$(hack/versions.sh)"            # musl (default): tag without suffix
#   eval "$(hack/versions.sh mimalloc)"   # mimalloc: tag with -mimalloc suffix
#
# The Dockerfile is the single source of truth; the checks and CI read it from
# here so a version bump is one line. The allocator is the one variant axis:
# musl keeps the existing tag, mimalloc appends -mimalloc.

set -euo pipefail

dockerfile="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/Dockerfile"

arg() {
    local value
    value=$(sed -nE "s/^ARG ${1}=([^[:space:]]+)\$/\\1/p" "${dockerfile}" | head -n1)
    [[ -n ${value} ]] || { printf 'versions: ARG %s not found in Dockerfile\n' "${1}" >&2; exit 1; }
    printf '%s' "${value}"
}

allocator="${1:-musl}"
case "${allocator}" in
    musl) suffix="" ;;
    mimalloc) suffix="-mimalloc" ;;
    *) printf 'versions: unknown allocator %q (want musl|mimalloc)\n' "${allocator}" >&2; exit 1 ;;
esac

qbt=$(arg QBT_VERSION)
lt=$(arg LT_VERSION)
march=$(arg MARCH)

printf 'QBT_VERSION=%q\n' "${qbt}"
printf 'LT_VERSION=%q\n' "${lt}"
printf 'MARCH=%q\n' "${march}"
printf 'ALLOCATOR=%q\n' "${allocator}"
printf 'MIMALLOC_TAG=%q\n' "$(arg MIMALLOC_TAG)"
printf 'MIMALLOC_SHA256=%q\n' "$(arg MIMALLOC_SHA256)"
printf 'IMAGE_TAG=%q\n' "${qbt}-lt${lt}-10g-${march}${suffix}"
