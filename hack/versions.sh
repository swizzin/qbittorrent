#!/usr/bin/env bash
# Print the versions and build axes the Dockerfile builds, as shell assignments:
#
#   eval "$(hack/versions.sh)"                                  # defaults
#   eval "$(hack/versions.sh mimalloc 10g znver3 amd64 1.2.20)"  # explicit axes
#   eval "$(hack/versions.sh musl base x86-64-v2 amd64 2.1.3)"   # the 2.1 line
#
# Positional arguments, in order: ALLOCATOR, PROFILE, MARCH, ARCH, LT. The
# Dockerfile is the single source of truth for the version pins and for the
# axis defaults (its own ARG defaults); passing an axis here overrides the
# default. Every axis is validated the way the Dockerfile validates it, so an
# impossible combination fails here instead of assembling a tag that names
# something the build then refuses (or worse, something it does not build).
# That includes the allocator, which is not a free axis: the Dockerfile builds
# base+musl and 10g+mimalloc and nothing else, so no other pairing is accepted.
#
# LT is the libtorrent release, given as its exact version (1.2.20 or 2.1.3).
# It defaults to the Dockerfile's LT_VERSION pin, and it is only accepted when
# this repository carries a patch pair for it: patches/libtorrent/<lt>/ is the
# directory the build script reads for -lt v<lt>, so a release without one
# cannot produce the image its tag claims.
#
# Tags name the libtorrent line (major.minor: 1.2, 2.1), never the patch
# release. A libtorrent patch bump re-points a variant's tags exactly as an
# OpenSSL, Boost or Qt bump does; the exact versions are in /app/BUILD-INFO and
# the image's labels. The names derived from the axes:
#
#   LT_LINE      1.2 | 2.1
#   SUFFIX       "" | -10g | -10g-znver3
#   VARIANT      lt<line><SUFFIX>          the rolling tag, any qBittorrent
#   IMAGE_TAG    <qbt>-<VARIANT>           the versioned tag
#   MINOR_TAG    <qbt minor>-<VARIANT>     the tag on the qBittorrent minor
#   LATEST       true for the one variant `latest` also names
#
# The allocator is not in a tag: it follows the profile, so `10g` says mimalloc
# and a tag with no profile says musl. It is still printed, because the build
# takes it as a build arg and BUILD-INFO records it.
#
# Every published tag is VARIANT with something in front of it or nothing:
# the rolling tag is VARIANT itself, the versioned tag puts the qBittorrent
# version in front, the minor tag puts the qBittorrent major.minor in front,
# the immutable tag puts the commit in front (sha-<12>-<VARIANT>), and a single
# image appends -<arch> (see the README's tags table). The default profile has
# no name in any tag. `latest` is the default profile on the Dockerfile's own
# LT_VERSION line. ARCH deliberately never appears in VARIANT: the default and
# 10g baseline tags are multi-arch manifests that combine amd64 and arm64 under
# one name.
#
# The minor tag is for the user a tracker has pinned to one qBittorrent minor:
# it moves with every build of its variant that carries a release of that
# minor, so the minor's patch releases and every libtorrent, OpenSSL, Boost or
# Alpine rebuild reach them without moving them off it. It is derived here
# beside the versioned tag, from the same QBT_VERSION, so it cannot name a
# version the build does not carry.

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${repo_root}/Dockerfile"

arg() {
    local value
    value=$(awk -v name="${1}" -F= '$1 == "ARG " name { print $2; exit }' "${dockerfile}")
    [[ -n ${value} ]] || { printf 'versions: ARG %s not found in Dockerfile\n' "${1}" >&2; exit 1; }
    printf '%s' "${value}"
}

allocator="${1:-$(arg ALLOCATOR)}"
profile="${2:-$(arg PROFILE)}"
march="${3:-$(arg MARCH)}"
arch="${4:-amd64}"
default_lt="$(arg LT_VERSION)"
lt="${5:-${default_lt}}"

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

# The arm64 build ignores MARCH: the Dockerfile compiles for the armv8-a
# baseline and records that in BUILD-INFO whatever MARCH says. Accepting
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

# A tag names the line, the release's first two numbers, so the release has to
# have exactly three.
if [[ ! ${lt} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'versions: libtorrent %q is not a major.minor.patch release\n' "${lt}" >&2
    exit 1
fi

# The libtorrent release has to be one this repository has patches for. A tag that
# names a libtorrent the build carries no compiled defaults for would be an
# image built on a different recipe under the same name.
if [[ ! -f ${repo_root}/patches/libtorrent/${lt}/patch \
    || ! -f ${repo_root}/patches/libtorrent/${lt}/base.patch ]]; then
    available=$(cd -- "${repo_root}/patches/libtorrent" && printf '%s\n' */ | tr -d / | tr '\n' ' ')
    printf 'versions: no libtorrent patch pair for %q (have: %s)\n' "${lt}" "${available% }" >&2
    exit 1
fi

# The allocator follows the profile, on every line and every architecture: base
# keeps musl's own malloc, 10g links mimalloc. The Dockerfile fails any other
# pairing, so refuse to name a tag for one.
case "${profile}:${allocator}" in
    base:musl|10g:mimalloc) ;;
    *)
        printf 'versions: the allocator follows the profile (base is musl, 10g is mimalloc), got profile %q with allocator %q\n' \
            "${profile}" "${allocator}" >&2
        exit 1
        ;;
esac

suffix=""
[[ ${profile} == "10g" ]] && suffix="-10g"
[[ ${march} == "znver3" ]] && suffix="${suffix}-znver3"

qbt=$(arg QBT_VERSION)
line="${lt%.*}"
variant="lt${line}${suffix}"
latest=false
[[ -z ${suffix} && ${line} == "${default_lt%.*}" ]] && latest=true

# The minor tag drops the qBittorrent patch release, so the version has to have
# one: a two-part QBT_VERSION would give a tag that claims a minor as a version.
if [[ ! ${qbt} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'versions: QBT_VERSION %q is not a major.minor.patch release\n' "${qbt}" >&2
    exit 1
fi
minor_tag="${qbt%.*}-${variant}"

printf 'QBT_VERSION=%q\n' "${qbt}"
printf 'LT_VERSION=%q\n' "${lt}"
printf 'LT_LINE=%q\n' "${line}"
printf 'PROFILE=%q\n' "${profile}"
printf 'MARCH=%q\n' "${march}"
printf 'ARCH=%q\n' "${arch}"
printf 'ALLOCATOR=%q\n' "${allocator}"
# Not %q: an empty suffix would print as '' and GITHUB_ENV takes it literally.
# The suffix is only ever -, letters and digits.
printf 'SUFFIX=%s\n' "${suffix}"
printf 'MIMALLOC_TAG=%q\n' "$(arg MIMALLOC_TAG)"
printf 'MIMALLOC_SHA256=%q\n' "$(arg MIMALLOC_SHA256)"
printf 'VARIANT=%q\n' "${variant}"
printf 'IMAGE_TAG=%q\n' "${qbt}-${variant}"
printf 'MINOR_TAG=%q\n' "${minor_tag}"
printf 'LATEST=%q\n' "${latest}"
