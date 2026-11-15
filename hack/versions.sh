#!/usr/bin/env bash
# Print the versions and build axes the Dockerfile builds, as shell assignments:
#
#   eval "$(hack/versions.sh)"                                  # defaults
#   eval "$(hack/versions.sh mimalloc 10g znver3 amd64 1.2.20)"  # explicit axes
#   eval "$(hack/versions.sh musl base x86-64-v2 amd64 2.1.2)"   # the 2.1 line
#
# Positional arguments, in order: ALLOCATOR, PROFILE, MARCH, ARCH, LT. The
# Dockerfile is the single source of truth for the version pins and for the
# axis defaults (its own ARG defaults); passing an axis here overrides the
# default. Every axis is validated the way the Dockerfile validates it, so an
# impossible combination fails here instead of assembling a tag that names
# something the build then refuses (or worse, something it does not build).
#
# LT is the libtorrent line, given as its exact tag version (1.2.20 or 2.1.2).
# It defaults to the Dockerfile's LT_VERSION pin, and it is only accepted when
# this repository carries a patch pair for it: patches/libtorrent/<lt>/ is the
# directory the build script reads for -lt v<lt>, so a line without one cannot
# produce the image its tag claims.
#
# Two names are derived from the axes:
#
#   SUFFIX       "" | -10g | -10g-znver3 | -10g-znver3-mimalloc
#   IMAGE_TAG    <qbt>-lt<lt><SUFFIX>
#
# The default profile has no name in any tag: the image people pull by default
# is just <qbt>-lt<lt>. Immutable tags carry the same suffix after this commit
# and the libtorrent line, sha-<12>-lt<lt><SUFFIX>, and a single image adds
# -<arch> (see the README's tags table). ARCH deliberately never appears in
# IMAGE_TAG: the default and 10g baseline tags are multi-arch manifests that
# combine amd64 and arm64 under one name.

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${repo_root}/Dockerfile"

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
lt="${5:-$(arg LT_VERSION)}"

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

# The libtorrent line has to be one this repository has patches for. A tag that
# names a libtorrent the build carries no compiled defaults for would be an
# image built on a different recipe under the same name.
if [[ ! -f ${repo_root}/patches/libtorrent/${lt}/patch \
    || ! -f ${repo_root}/patches/libtorrent/${lt}/base.patch ]]; then
    available=$(cd -- "${repo_root}/patches/libtorrent" && printf '%s\n' */ | tr -d / | tr '\n' ' ')
    printf 'versions: no libtorrent patch pair for %q (have: %s)\n' "${lt}" "${available% }" >&2
    exit 1
fi

# mimalloc is only built for the 1.2.20 10g-znver3 amd64 line; the Dockerfile
# fails any other combination, so refuse to name a tag for one.
if [[ ${allocator} == "mimalloc" ]] \
    && { [[ ${lt} != "1.2.20" ]] || [[ ${profile} != "10g" ]] || [[ ${march} != "znver3" ]] || [[ ${arch} != "amd64" ]]; }; then
    printf 'versions: mimalloc is only built for the 1.2.20 10g-znver3 amd64 line\n' >&2
    exit 1
fi

suffix=""
[[ ${profile} == "10g" ]] && suffix="-10g"
[[ ${march} == "znver3" ]] && suffix="${suffix}-znver3"
[[ ${allocator} == "mimalloc" ]] && suffix="${suffix}-mimalloc"

qbt=$(arg QBT_VERSION)

printf 'QBT_VERSION=%q\n' "${qbt}"
printf 'LT_VERSION=%q\n' "${lt}"
printf 'PROFILE=%q\n' "${profile}"
printf 'MARCH=%q\n' "${march}"
printf 'ARCH=%q\n' "${arch}"
printf 'ALLOCATOR=%q\n' "${allocator}"
# Not %q: an empty suffix would print as '' and GITHUB_ENV takes it literally.
# The suffix is only ever -, letters and digits.
printf 'SUFFIX=%s\n' "${suffix}"
printf 'MIMALLOC_TAG=%q\n' "$(arg MIMALLOC_TAG)"
printf 'MIMALLOC_SHA256=%q\n' "$(arg MIMALLOC_SHA256)"
printf 'IMAGE_TAG=%q\n' "${qbt}-lt${lt}${suffix}"
