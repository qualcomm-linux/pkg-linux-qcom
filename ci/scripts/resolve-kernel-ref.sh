#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
set -euo pipefail

# Resolve the kernel git ref to build.
#
# In --latest-tag mode: queries the remote repository for tags matching a
# matrix-provided pattern and returns the one with the most recent trailing
# YYYYMMDD snapshot. Date-based sorting is used (not version sort) so that a
# newer-dated rc always wins over an older-dated final release.
#
# In --ref mode: validates the given ref is non-empty and returns it as-is.
# This is the passthrough path for pinned release builds.
#
# Usage:
#   ci/scripts/resolve-kernel-ref.sh --url <kernel_url> --latest-tag '<pattern>'
#   ci/scripts/resolve-kernel-ref.sh --url <kernel_url> --ref <tag_or_branch>
#
# Options:
#   --url URL              Kernel repository URL. Required.
#   --latest-tag PATTERN   Resolve the newest dated tag matching PATTERN.
#   --ref REF              Use this ref directly (passthrough for branch and
#                          pinned builds).
#
# Output:
#   Resolved ref printed to stdout.
#
# Exit codes:
#   0  Success.
#   1  Error (missing args, no tags found, empty ref).

URL=""
LATEST_TAG_PATTERN=""
REF=""

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --url)        URL="$2";                shift 2 ;;
        --latest-tag) LATEST_TAG_PATTERN="$2"; shift 2 ;;
        --ref)        REF="$2";                shift 2 ;;
        -h|--help)    usage ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage ;;
    esac
done

[[ -n "$URL" ]] || { echo "ERROR: --url is required" >&2; exit 1; }

if [[ -n "$LATEST_TAG_PATTERN" && -n "$REF" ]]; then
    echo "ERROR: --latest-tag and --ref are mutually exclusive" >&2
    exit 1
fi

if [[ -z "$LATEST_TAG_PATTERN" && -z "$REF" ]]; then
    echo "ERROR: one of --latest-tag or --ref is required" >&2
    exit 1
fi

if [[ -n "$LATEST_TAG_PATTERN" ]]; then
    # Query remote tags matching the matrix-provided pattern.
    # Sort by the trailing 8-digit date (field after last -), pick the newest.
    # Using date-based sort rather than version sort (-V) because version sort
    # keys on the base kernel version first, causing an older-dated rc to
    # outrank a newer-dated final release.
    RESOLVED=$(
        git ls-remote --tags "$URL" "refs/tags/${LATEST_TAG_PATTERN}" \
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
        echo "ERROR: No dated tags matching '${LATEST_TAG_PATTERN}' found in $URL" >&2
        exit 1
    }
    echo "$RESOLVED"
else
    [[ -n "$REF" ]] || { echo "ERROR: --ref value is empty" >&2; exit 1; }
    echo "$REF"
fi
