#!/bin/bash
set -euo pipefail

# Derive the LOCALVERSION suffix from a kernel ref (tag or branch tip).
#
# For tag builds (ref matches qcom-next-<kver>-<YYYYMMDD>):
#   Extracts the prefix and date, produces -<prefix>-<date>.
#   Example: qcom-next-7.2-rc3-20260722 -> -qcom-next-20260722
#
# For branch-tip builds (ref does not match the tag pattern):
#   Uses the branch name and a short SHA for uniqueness.
#   Example: qcom-next @ 07f50dc44edd -> -qcom-next-g07f50dc44edd
#   --sha is required for branch-tip builds.
#
# Usage:
#   ci/scripts/derive-localversion.sh --ref qcom-next-7.2-rc3-20260722
#   ci/scripts/derive-localversion.sh --ref qcom-next --sha 07f50dc44edd
#
# Options:
#   --ref REF    Kernel ref (tag name or branch name). Required.
#   --sha SHA    Short commit SHA (required for branch-tip builds).
#
# Output:
#   LOCALVERSION suffix printed to stdout (e.g. -qcom-next-20260722).
#   Always starts with a dash.
#
# Exit codes:
#   0  Success.
#   1  Error (missing args, branch-tip without --sha).

REF=""
SHA=""

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --ref) REF="$2"; shift 2 ;;
        --sha) SHA="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage ;;
    esac
done

[[ -n "$REF" ]] || { echo "ERROR: --ref is required" >&2; exit 1; }

# Try to match the tag pattern: <prefix>-<kver>-<YYYYMMDD>
# where prefix is lowercase letters and hyphens, kver contains dots and digits,
# and the trailing component is exactly 8 digits.
if [[ "$REF" =~ ^([a-z-]+)-[0-9]+\.[0-9]+.*-([0-9]{8})$ ]]; then
    PREFIX="${BASH_REMATCH[1]}"
    DATE="${BASH_REMATCH[2]}"
    echo "-${PREFIX}-${DATE}"
else
    # Branch-tip build: need SHA for uniqueness.
    [[ -n "$SHA" ]] || {
        echo "ERROR: --sha is required for branch-tip builds (ref '$REF' does not match tag pattern)" >&2
        exit 1
    }
    # Use first 12 chars of SHA for a compact but unambiguous suffix.
    SHORT_SHA="${SHA:0:12}"
    echo "-${REF}-g${SHORT_SHA}"
fi
