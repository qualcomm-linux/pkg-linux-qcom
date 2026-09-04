#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
set -euo pipefail

# Derive the LOCALVERSION suffix from a kernel variant and resolved ref.
#
# For dated tag builds (ref ends in -YYYYMMDD):
#   Produces +<kernel-variant>-<date>.
#   Example: qcom-next-7.2-rc3-20260722 -> +qcom-next-20260722
#
# For branch-tip builds (ref does not end in a date):
#   Uses the kernel variant and a short SHA for uniqueness.
#   Example: qcom-next @ 07f50dc44edd -> +qcom-next-g07f50dc44edd
#   --sha is required for branch-tip builds.
#
# Why the leading '+' and not '-':
#   The suffix ends up in KERNELRELEASE (uname -r), which is the 'version' field
#   systemd-boot sorts BLS entries on. systemd compares the separator before the
#   chunk behind it, and '-' < '+', so joining with '+' puts every -rcN release
#   candidate BELOW the final release that follows it:
#
#     7.2.0-rc7+qcom-next-20260821  <  7.2.0+qcom-next-20260826
#
#   Joining with '-' instead falls through to a plain strcmp of "rc" against
#   "qcom", where 'r' > 'q', and every rc outranks its own final release in the
#   boot menu. This is the same trick Debian's own kernels rely on
#   (linux-image-7.1.10+deb14-amd64). It does not affect the Debian version,
#   which spells the release candidate ~rcN and orders correctly either way.
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
#   LOCALVERSION suffix printed to stdout (e.g. +qcom-next-20260722).
#   Always starts with a plus.
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
    echo "+${VARIANT}-${DATE}"
else
    # Branch-tip build: need SHA for uniqueness.
    [[ -n "$SHA" ]] || {
        echo "ERROR: --sha is required for branch-tip builds (ref '$REF' is not a dated tag)" >&2
        exit 1
    }
    # Use first 12 chars of SHA for a compact but unambiguous suffix.
    SHORT_SHA="${SHA:0:12}"
    echo "+${VARIANT}-g${SHORT_SHA}"
fi
