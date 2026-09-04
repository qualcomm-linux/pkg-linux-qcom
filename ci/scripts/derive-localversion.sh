#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
set -euo pipefail

# Derive the version fields for a build from a kernel variant and resolved ref.
#
# Emits LOCALVERSION (the kernel release suffix), SNAPSHOT (the dated component
# of the Debian version) and GITSHA, all derived from the ref in one place.
# SNAPSHOT and GITSHA are emitted alongside rather than recovered from
# LOCALVERSION later: reading them back out means guessing where each field ends
# in a string that also carries a variant name, and a hex SHA can end in eight
# digits of its own.
#
# For dated tag builds (ref ends in -YYYYMMDD, optionally .<respin>):
#   Produces +<kernel-variant>-<date>[.<respin>]-g<12 hex>.
#   Example: qcom-next-7.2-rc3-20260722   -> +qcom-next-20260722-g07f50dc44edd
#            qcom-next-7.2-rc3-20260722.1 -> +qcom-next-20260722.1-g07f50dc44edd
#
#   The respin ordinal distinguishes a second tag cut on the same day. It is
#   carried verbatim rather than normalised, so the first tag of a day stays
#   plain +<variant>-<date>: systemd compares the separator before the chunk
#   behind it, so an absent ordinal already sorts below a present one and no
#   build has to spell a ".0".
#
#   The SHA names the commit the tag pointed at when the build was cut, so a
#   moved tag cannot silently produce two different kernels under one release.
#
# For branch-tip builds (ref does not end in a date):
#   Uses the kernel variant and the SHA alone; there is no date to order by.
#   Example: qcom-next @ 07f50dc44edd -> +qcom-next-g07f50dc44edd
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
#   ci/scripts/derive-localversion.sh --variant qcom-next --ref qcom-next-7.2-rc3-20260722 --sha 07f50dc44edd
#   ci/scripts/derive-localversion.sh --variant arduino --ref main --sha 07f50dc44edd
#
# Options:
#   --variant VARIANT  Kernel variant identifier. Defaults to qcom-next.
#   --ref REF          Kernel ref (tag name or branch name). Required.
#   --sha SHA          Commit SHA, truncated to 12 hex characters. Required.
#
# Output:
#   Three KEY=VALUE lines on stdout, in GITHUB_ENV / 'set -a' form:
#
#     LOCALVERSION=+qcom-next-20260722.1-g07f50dc44edd
#     SNAPSHOT=20260722.1
#     GITSHA=07f50dc44edd
#
#   LOCALVERSION always starts with a plus. SNAPSHOT is empty for branch-tip
#   builds, which have no date; the Debian version then carries no snapshot
#   component at all.
#
# Exit codes:
#   0  Success.
#   1  Error (invalid args, missing or malformed --sha).

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
# Every build identifies its commit, so --sha is required for all of them, not
# just the branch tips that cannot be identified any other way.
[[ "$SHA" =~ ^[0-9a-f]{12,40}$ ]] || {
    echo "ERROR: --sha is required and must be at least 12 lowercase hex characters (got '$SHA')" >&2
    exit 1
}
# 12 chars is upstream's own abbreviation width in -g<hash>, and short enough
# to keep the kernel release readable in a boot menu.
GITSHA="${SHA:0:12}"

# Dated tags use a trailing YYYYMMDD snapshot, optionally followed by a respin
# ordinal. The matrix selects the tag set; the variant supplies the stable
# package identity used in LOCALVERSION.
if [[ "$REF" =~ -([0-9]{8}(\.[0-9]+)?)$ ]]; then
    SNAPSHOT="${BASH_REMATCH[1]}"
    LOCALVERSION="+${VARIANT}-${SNAPSHOT}-g${GITSHA}"
else
    # Branch-tip build: no date, so the SHA is the whole identity.
    LOCALVERSION="+${VARIANT}-g${GITSHA}"
    SNAPSHOT=""
fi

echo "LOCALVERSION=${LOCALVERSION}"
echo "SNAPSHOT=${SNAPSHOT}"
echo "GITSHA=${GITSHA}"
