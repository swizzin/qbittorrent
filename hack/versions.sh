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
# default. Every axis is validated the way the Dockerfile validates it, so an
# impossible combination fails here instead of assembling a tag that names
# something the build then refuses (or worse, something it does not build).
#
# Two names are derived from the axes:
#
#   VARIANT      base | 10g | 10g-znver3 | 10g-znver3-mimalloc
#   IMAGE_TAG    <qbt>-lt<lt>[-10g][-znver3][-mimalloc]
#
# VARIANT is the variant for immutable tags: a build of one commit is
# sha-<12>-<variant>, and a single image adds -<arch> (see the README's tags
# table). ARCH deliberately never appears in IMAGE_TAG: the base and 10g
# baseline tags are multi-arch manifests that combine amd64 and arm64 under one
# name.

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

case "${profile}" in
    base|10g) ;;
    *) printf 'versions: unknown profile %q (want base|10g)\n' "${profile}" >&2; exit 1 ;;
esac

case "${arch}" in
    amd64|arm64) ;;
    *) printf 'versions: unknown arch %q (want amd64|arm64)\n' "${arch}" >&2; exit 1 ;;
esac

# The arm64 build ignores MARCH: the Dockerfile compiles the cross toolchain's
# armv8-a baseline and records that in BUILD-INFO whatever MARCH says. Accepting
# another value here would produce a tag (and a BUILD-INFO) that disagrees.
case "${arch}:${march}" in
    amd64:x86-64-v2|amd64:znver3|arm64:armv8-a) ;;
    arm64:*)
        printf 'versions: arm64 is compiled for armv8-a, got march %q for arm64\n' "${march}" >&2
        exit 1
        ;;
    *)
        printf 'versions: unknown march %q for %s (want x86-64-v2 or znver3)\n' "${march}" "${arch}" >&2
        exit 1
        ;;
esac

# mimalloc is only built for the 10g-znver3 amd64 line; the Dockerfile fails any
# other combination, so refuse to name a tag for one.
if [[ ${allocator} == "mimalloc" ]] \
    && { [[ ${profile} != "10g" ]] || [[ ${march} != "znver3" ]] || [[ ${arch} != "amd64" ]]; }; then
    printf 'versions: mimalloc is only built for the 10g-znver3 amd64 line\n' >&2
    exit 1
fi

variant="${profile}"
[[ ${march} == "znver3" ]] && variant="${variant}-znver3"
[[ ${allocator} == "mimalloc" ]] && variant="${variant}-mimalloc"

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
printf 'VARIANT=%q\n' "${variant}"
printf 'MIMALLOC_TAG=%q\n' "$(arg MIMALLOC_TAG)"
printf 'MIMALLOC_SHA256=%q\n' "$(arg MIMALLOC_SHA256)"
printf 'IMAGE_TAG=%q\n' "${qbt}-lt${lt}${suffix}"
