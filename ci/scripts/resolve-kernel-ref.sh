#!/bin/bash
set -euo pipefail

# Resolve the kernel git ref to build.
#
# In --latest mode: queries the remote repository for all qcom-next-*-YYYYMMDD
# tags and returns the one with the most recent date snapshot. Date-based sort
# is used (not version sort) so that a newer-dated rc always wins over an
# older-dated final release.
#
# In --ref mode: validates the given ref is non-empty and returns it as-is.
# This is the passthrough path for pinned release builds.
#
# Usage:
#   ci/scripts/resolve-kernel-ref.sh --url <kernel_url> --latest
#   ci/scripts/resolve-kernel-ref.sh --url <kernel_url> --ref <tag_or_branch>
#
# Options:
#   --url URL    Kernel repository URL. Required.
#   --latest     Resolve the latest qcom-next-*-YYYYMMDD tag from the remote.
#   --ref REF    Use this ref directly (passthrough for pinned builds).
#
# Output:
#   Resolved ref printed to stdout (e.g. qcom-next-7.2-rc3-20260722).
#
# Exit codes:
#   0  Success.
#   1  Error (missing args, no tags found, empty ref).

URL=""
LATEST=false
REF=""

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --url)     URL="$2";   shift 2 ;;
        --latest)  LATEST=true; shift  ;;
        --ref)     REF="$2";   shift 2 ;;
        -h|--help) usage ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage ;;
    esac
done

[[ -n "$URL" ]] || { echo "ERROR: --url is required" >&2; exit 1; }

if [[ "$LATEST" == true && -n "$REF" ]]; then
    echo "ERROR: --latest and --ref are mutually exclusive" >&2
    exit 1
fi

if [[ "$LATEST" == false && -z "$REF" ]]; then
    echo "ERROR: one of --latest or --ref is required" >&2
    exit 1
fi

if [[ "$LATEST" == true ]]; then
    # Query remote tags matching qcom-next-*-YYYYMMDD.
    # Sort by the trailing 8-digit date (field after last -), pick the newest.
    # Using date-based sort rather than version sort (-V) because version sort
    # keys on the base kernel version first, causing an older-dated rc to
    # outrank a newer-dated final release.
    RESOLVED=$(
        git ls-remote --tags "$URL" 'refs/tags/qcom-next-*' \
            | awk '{print $2}' \
            | sed 's|refs/tags/||' \
            | grep -v '\^{}' \
            | grep -E -- '-[0-9]{8}$' \
            | awk -F- '{print $NF"\t"$0}' \
            | sort -k1,1n \
            | tail -1 \
            | cut -f2-
    )
    [[ -n "$RESOLVED" ]] || {
        echo "ERROR: No qcom-next-*-YYYYMMDD tags found in $URL" >&2
        exit 1
    }
    echo "$RESOLVED"
else
    [[ -n "$REF" ]] || { echo "ERROR: --ref value is empty" >&2; exit 1; }
    echo "$REF"
fi
