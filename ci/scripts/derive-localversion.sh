#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
set -euo pipefail

# Derive the LOCALVERSION suffix from a kernel variant and resolved ref.
#
# For dated tag builds (ref ends in -YYYYMMDD):
#   Produces -<kernel-variant>-<date>.
#   Example: qcom-next-7.2-rc3-20260722 -> -qcom-next-20260722
#
# For branch-tip builds (ref does not end in a date):
#   Uses the kernel variant and a short SHA for uniqueness.
#   Example: qcom-next @ 07f50dc44edd -> -qcom-next-g07f50dc44edd
#   --sha is required for branch-tip builds.
#
# Usage:
#   ci/scripts/derive-localversion.sh --variant qcom-next --ref qcom-next-7.2-rc3-20260722
#   ci/scripts/derive-localversion.sh --variant arduino --ref main --sha 07f50dc44edd
#
# Options:
#   --variant VARIANT  Kernel variant identifier. Defaults to qcom-next.
#   --ref REF          Kernel ref (tag name or branch name). Required.
#   --sha SHA          Short commit SHA (required for branch-tip builds).
#
# Output:
#   LOCALVERSION suffix printed to stdout (e.g. -qcom-next-20260722).
#   Always starts with a dash.
#
# Exit codes:
#   0  Success.
#   1  Error (invalid args, branch-tip without --sha).

VARIANT="qcom-next"
REF=""
SHA=""

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --variant) VARIANT="$2"; shift 2 ;;
        --ref)     REF="$2";     shift 2 ;;
        --sha)     SHA="$2";     shift 2 ;;
        -h|--help) usage ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage ;;
    esac
done

[[ -n "$REF" ]] || { echo "ERROR: --ref is required" >&2; exit 1; }
[[ "$VARIANT" =~ ^[a-z0-9]+([a-z0-9-]*[a-z0-9])?$ ]] || {
    echo "ERROR: --variant must use lowercase letters, digits, and internal hyphens" >&2
    exit 1
}

# Dated tags use a trailing YYYYMMDD snapshot. The matrix selects the tag set;
# the variant supplies the stable package identity used in LOCALVERSION.
if [[ "$REF" =~ -([0-9]{8})$ ]]; then
    DATE="${BASH_REMATCH[1]}"
    echo "-${VARIANT}-${DATE}"
else
    # Branch-tip build: need SHA for uniqueness.
    [[ -n "$SHA" ]] || {
        echo "ERROR: --sha is required for branch-tip builds (ref '$REF' is not a dated tag)" >&2
        exit 1
    }
    # Use first 12 chars of SHA for a compact but unambiguous suffix.
    SHORT_SHA="${SHA:0:12}"
    echo "-${VARIANT}-g${SHORT_SHA}"
fi
