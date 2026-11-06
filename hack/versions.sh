#!/usr/bin/env bash
# Print the versions and build axes the Dockerfile builds, as shell assignments:
#
#   eval "$(hack/versions.sh)"                              # defaults (10g-znver3-musl)
#   eval "$(hack/versions.sh mimalloc 10g znver3 amd64)"    # explicit axes
#   eval "$(hack/versions.sh musl base x86-64-v2 amd64)"    # base, baseline amd64
#
# Positional arguments, in order: ALLOCATOR, PROFILE, MARCH, ARCH. The
# Dockerfile is the single source of truth for the version pins and for the
# axis defaults (its own ARG defaults); passing an axis here overrides the
# default. The tag is assembled from the axes:
#
#   <qbt>-lt<lt>[-10g][-znver3][-mimalloc]
#
# ARCH deliberately never appears in the tag: the base and 10g baseline tags
# are multi-arch manifests that combine amd64 and arm64 under one name.

set -euo pipefail

dockerfile="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/Dockerfile"

arg() {
    local value
    value=$(awk -v name="${1}" -F= '$1 == "ARG " name { print $2; exit }' "${dockerfile}")
    [[ -n ${value} ]] || { printf 'versions: ARG %s not found in Dockerfile\n' "${1}" >&2; exit 1; }
    printf '%s' "${value}"
}

allocator="${1:-musl}"
profile="${2:-$(arg PROFILE)}"
march="${3:-$(arg MARCH)}"
arch="${4:-amd64}"

case "${allocator}" in
    musl|mimalloc) ;;
    *) printf 'versions: unknown allocator %q (want musl|mimalloc)\n' "${allocator}" >&2; exit 1 ;;
esac

suffix=""
[[ ${profile} == "10g" ]] && suffix="-10g"
[[ ${march} == "znver3" ]] && suffix="${suffix}-znver3"
[[ ${allocator} == "mimalloc" ]] && suffix="${suffix}-mimalloc"

qbt=$(arg QBT_VERSION)
lt=$(arg LT_VERSION)

printf 'QBT_VERSION=%q\n' "${qbt}"
printf 'LT_VERSION=%q\n' "${lt}"
printf 'PROFILE=%q\n' "${profile}"
printf 'MARCH=%q\n' "${march}"
printf 'ARCH=%q\n' "${arch}"
printf 'ALLOCATOR=%q\n' "${allocator}"
printf 'MIMALLOC_TAG=%q\n' "$(arg MIMALLOC_TAG)"
printf 'MIMALLOC_SHA256=%q\n' "$(arg MIMALLOC_SHA256)"
printf 'IMAGE_TAG=%q\n' "${qbt}-lt${lt}${suffix}"
