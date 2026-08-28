#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
set -euo pipefail

# Derive the LOCALVERSION suffix from a kernel variant and resolved ref.
#
# Every suffix ends in the build date. debian/rules reads the trailing
# -YYYYMMDD out of LOCALVERSION and uses it as the package version's upstream
# date component (<base_kver>+<date>-<revision>), so without a trailing date
# two builds of the same base kernel version produce the same package version,
# and the second cannot be published alongside the first. Only the build date
# advances on every build; a tag date does not (a week with no new tag repeats
# it) and a SHA is not a date at all.
#
# For dated tag builds (ref ends in -YYYYMMDD):
#   Produces -<kernel-variant>-<tag-date>-<build-date>. The tag date is kept
#   because it names the upstream snapshot; the build date is what makes the
#   version advance.
#   Example: qcom-next-7.2-rc3-20260722 built on 2026-08-28
#            -> -qcom-next-20260722-20260828
#
# For branch-tip builds (ref does not end in a date):
#   Uses the kernel variant, a short SHA to identify the commit, and the build
#   date.
#   Example: qcom-next @ 07f50dc44edd built on 2026-08-28
#            -> -qcom-next-g07f50dc44edd-20260828
#   --sha is required for branch-tip builds.
#
# Usage:
#   ci/scripts/derive-localversion.sh --variant qcom-next --ref qcom-next-7.2-rc3-20260722
#   ci/scripts/derive-localversion.sh --variant qcom-arduino --ref main --sha 07f50dc44edd
#   ci/scripts/derive-localversion.sh --variant next --ref next-20260827 --build-date 20260828
#
# Options:
#   --variant VARIANT     Kernel variant identifier. Defaults to qcom-next.
#   --ref REF             Kernel ref (tag name or branch name). Required.
#   --sha SHA             Short commit SHA (required for branch-tip builds).
#   --build-date YYYYMMDD Build date to append. Defaults to today in UTC. Each
#                           build leg computes this independently, so a run
#                           that crosses midnight UTC can date its legs a day
#                           apart; pass this explicitly to pin one date across
#                           a run. Legs differ by suite revision regardless, so
#                           a split date costs nothing but tidiness.
#
# Output:
#   LOCALVERSION suffix printed to stdout
#   (e.g. -qcom-next-20260722-20260828). Always starts with a dash and always
#   ends in an 8-digit date.
#
# Exit codes:
#   0  Success.
#   1  Error (invalid args, branch-tip without --sha, malformed build date).

VARIANT="qcom-next"
REF=""
SHA=""
BUILD_DATE=""

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --variant)    VARIANT="$2";    shift 2 ;;
        --ref)        REF="$2";        shift 2 ;;
        --sha)        SHA="$2";        shift 2 ;;
        --build-date) BUILD_DATE="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage ;;
    esac
done

[[ -n "$REF" ]] || { echo "ERROR: --ref is required" >&2; exit 1; }
[[ "$VARIANT" =~ ^[a-z0-9]+([a-z0-9-]*[a-z0-9])?$ ]] || {
    echo "ERROR: --variant must use lowercase letters, digits, and internal hyphens" >&2
    exit 1
}

# Default to today in UTC so a build's date does not depend on runner timezone.
[[ -n "$BUILD_DATE" ]] || BUILD_DATE=$(date -u +%Y%m%d)
[[ "$BUILD_DATE" =~ ^[0-9]{8}$ ]] || {
    echo "ERROR: --build-date must be 8 digits (YYYYMMDD), got '$BUILD_DATE'" >&2
    exit 1
}

# Dated tags use a trailing YYYYMMDD snapshot. The matrix selects the tag set;
# the variant supplies the stable package identity used in LOCALVERSION.
# The build date is appended last in both cases: debian/rules anchors its date
# extraction to the end of LOCALVERSION, so whatever trails here is what
# advances the package version.
if [[ "$REF" =~ -([0-9]{8})$ ]]; then
    TAG_DATE="${BASH_REMATCH[1]}"
    echo "-${VARIANT}-${TAG_DATE}-${BUILD_DATE}"
else
    # Branch-tip build: need SHA to identify the commit.
    [[ -n "$SHA" ]] || {
        echo "ERROR: --sha is required for branch-tip builds (ref '$REF' is not a dated tag)" >&2
        exit 1
    }
    # Use first 12 chars of SHA for a compact but unambiguous suffix.
    SHORT_SHA="${SHA:0:12}"
    echo "-${VARIANT}-g${SHORT_SHA}-${BUILD_DATE}"
fi
