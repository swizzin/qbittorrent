#!/usr/bin/env bash
# Regenerate the libtorrent compiled-defaults patch pair for one release.
#
#   hack/lt-patches.sh <version>        # for example 2.1.3
#
# Writes patches/libtorrent/<version>/patch (the 10g profile) and base.patch
# (the base profile) from that release tag's own src/settings_pack.cpp, then
# proves both against a pristine copy of the tag: `git apply --check -p1`,
# `patch -p1 --dry-run`, and a real apply that has to reproduce the tree this
# script generated and rewrite exactly six lines (10g) or five (base).
#
# The rewrites are written as "the stock line, and the line to put there
# instead", never as line numbers. A release that renumbers, reformats or
# restates one of them is then a stop, not a patch that quietly changes
# nothing: a hunk that no longer matches is exactly how a compiled default
# stops being compiled in without anyone noticing. What the six are and why is
# in patches/libtorrent/README.md; each value is the same on every libtorrent
# line, which is why one table covers the whole directory.
#
# The tag is the pin: the source comes from GitHub's codeload for arvidn/
# libtorrent at v<version>, unpacked once into
# ${QBT_LT_CACHE:-${TMPDIR:-/tmp}/qbt-lt-patches} so re-runs and the
# verification passes work without the network.

set -euo pipefail

usage() {
    printf 'usage: %s <version>\n' "${0##*/}" >&2
    exit 2
}

[[ $# -eq 1 ]] || usage
version="${1#v}"
if [[ ! ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'lt-patches: %q is not a libtorrent major.minor.patch release\n' "${version}" >&2
    exit 2
fi

for tool in awk cp diff git grep patch tar; do
    command -v "${tool}" >/dev/null 2>&1 || {
        printf 'lt-patches: host tool not found: %s\n' "${tool}" >&2
        exit 2
    }
done

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cache="${QBT_LT_CACHE:-${TMPDIR:-/tmp}/qbt-lt-patches}"
tag="v${version}"

# One row per setting: <name> <stock value> <base value> <10g value>. An empty
# base value means the base profile keeps the stock line, which is the case for
# the two tunings that scale with the box: only 10g raises them.
rows=(
    "request_timeout|60|20|20"
    "whole_pieces_threshold|20|10|10"
    "max_peer_recv_buffer_size|2 * 1024 * 1024||4 * 1024 * 1024"
    "torrent_connect_boost|30|50|50"
    "predictive_piece_announce|0|10|10"
    "send_not_sent_low_watermark|16384|524288|1024 * 1024"
)

# A cached tree is reused only when it holds the one file the patch touches; the
# directory name is the tag, so a stale or half-unpacked cache is re-fetched
# rather than silently patched against the wrong release.
pristine="${cache}/${tag}"
if [[ ! -f ${pristine}/src/settings_pack.cpp ]]; then
    command -v curl >/dev/null 2>&1 || {
        printf 'lt-patches: %s is not cached and curl is not installed\n' "${tag}" >&2
        exit 2
    }
    rm -rf "${pristine}"
    mkdir -p "${pristine}"
    tarball="${cache}/${tag}.tar.gz"
    curl -fsSL -o "${tarball}" \
        "https://codeload.github.com/arvidn/libtorrent/tar.gz/refs/tags/${tag}"
    # Only the file the patch edits: the tag's directory name in the archive is
    # the tag, so a wrong or moved tag fails here rather than at patch time.
    tar -xzf "${tarball}" -C "${pristine}" --strip-components=1 \
        "libtorrent-${version}/src/settings_pack.cpp"
    rm -f "${tarball}"
fi
if [[ ! -s ${pristine}/src/settings_pack.cpp ]]; then
    printf 'lt-patches: %s/src/settings_pack.cpp is missing or empty\n' "${pristine}" >&2
    exit 1
fi
printf 'source: %s\n' "${pristine}/src/settings_pack.cpp"

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

# Read the chosen profile's value out of a row.
value_for() { # <row> <profile>
    local setting stock base ten
    IFS='|' read -r setting stock base ten <<<"${1}"
    case "${2}" in
        base) printf '%s' "${base}" ;;
        10g) printf '%s' "${ten}" ;;
    esac
}

# Apply the profile's rewrites to a copy of the stock file. Each replacement
# has to find its stock line exactly once: zero means upstream moved or
# restated it, more than once means the table is ambiguous and the patch would
# hit the wrong one.
modify() { # <profile> <out>
    local profile="${1}" out="${2}" row setting stock from to hits
    cp "${pristine}/src/settings_pack.cpp" "${out}"
    for row in "${rows[@]}"; do
        IFS='|' read -r setting stock _ _ <<<"${row}"
        to=$(value_for "${row}" "${profile}")
        [[ -n ${to} ]] || continue
        from=$(printf '\t\tSET(%s, %s, nullptr),' "${setting}" "${stock}")
        hits=$(grep -cFx -- "${from}" "${out}" || true)
        if [[ ${hits} -ne 1 ]]; then
            printf 'lt-patches: %s: %s matches this line %s times:\n  %s\n' \
                "${tag}" "${setting}" "${hits}" "${from}" >&2
            printf 'lt-patches: read the tag'"'"'s settings_pack.cpp and the table in patches/libtorrent/README.md\n' >&2
            return 1
        fi
        awk -v from="${from}" \
            -v to="$(printf '\t\tSET(%s, %s, nullptr),' "${setting}" "${to}")" \
            '$0 == from { print to; next } { print }' "${out}" >"${out}.new"
        mv "${out}.new" "${out}"
    done
}

# A unified diff of the whole file, in the header form this repository commits:
# two paths, no timestamps, no blob hashes (the header's hashes are an artefact
# of whichever tool produced a file, not of the change).
make_patch() { # <modified> <out>
    local modified="${1}" out="${2}" rc=0
    diff -U3 "${pristine}/src/settings_pack.cpp" "${modified}" >"${tmp}/body" || rc=$?
    if [[ ${rc} -ne 1 ]]; then
        printf 'lt-patches: %s: the rewrites produced no diff (diff exited %s)\n' "${tag}" "${rc}" >&2
        return 1
    fi
    {
        printf 'diff --git a/src/settings_pack.cpp b/src/settings_pack.cpp\n'
        printf -- '--- a/src/settings_pack.cpp\n'
        printf -- '+++ b/src/settings_pack.cpp\n'
        tail -n +3 "${tmp}/body"
    } >"${out}"
}

# Prove a patch on a pristine copy: git's checker, patch's checker, a real
# apply, and then compare what was applied with what was generated. The last
# one is the assertion that matters: the tree the build compiles is the tree
# this script wrote the defaults for.
verify() { # <patch> <modified> <expected rewritten lines> <label>
    local patch_file="${1}" modified="${2}" want="${3}" label="${4}"
    local dir="${tmp}/verify-${label}" added removed files
    cp -a "${pristine}" "${dir}"
    (
        cd "${dir}"
        git apply --check -p1 "${patch_file}"
        patch -p1 --dry-run --silent <"${patch_file}"
        patch -p1 --silent <"${patch_file}"
    )
    if ! cmp -s "${modified}" "${dir}/src/settings_pack.cpp"; then
        printf 'lt-patches: %s: %s does not reproduce the generated tree\n' "${tag}" "${label}" >&2
        return 1
    fi
    files=$(grep -c '^diff --git ' "${patch_file}" || true)
    added=$(grep -cE '^\+[^+]' "${patch_file}" || true)
    removed=$(grep -cE '^-[^-]' "${patch_file}" || true)
    if [[ ${files} -ne 1 || ${added} -ne ${want} || ${removed} -ne ${want} ]]; then
        printf 'lt-patches: %s: %s rewrites %s lines in %s file(s), expected %s in one\n' \
            "${tag}" "${label}" "${added}" "${files}" "${want}" >&2
        return 1
    fi
    printf 'ok    %s: %s lines, git apply --check and patch --dry-run pass\n' "${label}" "${want}"
}

# The two profiles, in the order the README lists them: 10g is `patch`, base is
# `base.patch`, and the Dockerfile stages exactly one of them, so they must
# never merge into one file.
for profile in 10g base; do
    case "${profile}" in
        10g) name="patch"; want=6 ;;
        base) name="base.patch"; want=5 ;;
    esac
    modify "${profile}" "${tmp}/${profile}.cpp"
    make_patch "${tmp}/${profile}.cpp" "${tmp}/${name}"
    target="${repo_root}/patches/libtorrent/${version}/${name}"
    mkdir -p "$(dirname -- "${target}")"
    if cmp -s "${tmp}/${name}" "${target}" 2>/dev/null; then
        state="unchanged"
    else
        state="written"
        cp "${tmp}/${name}" "${target}"
    fi
    verify "${target}" "${tmp}/${profile}.cpp" "${want}" "${profile}"
    printf 'ok    %s (%s) sha256=%s\n\n' \
        "${target#"${repo_root}/"}" "${state}" "$(sha256sum "${target}" | cut -d' ' -f1)"
done

printf 'lt-patches: %s\n' "${version}"
