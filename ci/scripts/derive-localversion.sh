#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
set -euo pipefail

# Derive the version fields for a build from a kernel flavour and resolved ref.
#
# The flavour is the kernel's own identity, the part of the kernel release
# that distinguishes two kernels built from the same ref with different
# configuration, so that their linux-image packages install alongside each
# other. It is not the CI identifier for the build: a flavour is built for
# several suites, and all of those builds produce the same kernel release.
#
# Emits LOCALVERSION (the kernel release suffix), SNAPSHOT (the dated component
# of the Debian version) and GITSHA, all derived from the ref in one place.
# SNAPSHOT and GITSHA are emitted alongside rather than recovered from
# LOCALVERSION later: reading them back out means guessing where each field ends
# in a string that also carries a flavour name, and a hex SHA can end in eight
# digits of its own.
#
# For dated tag builds (ref ends in -YYYYMMDD, optionally .<respin>):
#   Produces +<flavour>-<date>[.<respin>]-g<12 hex>.
#   Example: qcom-next-7.2-rc3-20260722   -> +qcom-next-20260722-g07f50dc44edd
#            qcom-next-7.2-rc3-20260722.1 -> +qcom-next-20260722.1-g07f50dc44edd
#
#   The respin ordinal distinguishes a second tag cut on the same day. It is
#   carried verbatim rather than normalised, so the first tag of a day stays
#   plain +<flavour>-<date>: systemd compares the separator before the chunk
#   behind it, so an absent ordinal already sorts below a present one and no
#   build has to spell a ".0".
#
#   The SHA names the commit the tag pointed at when the build was cut, so a
#   moved tag cannot silently produce two different kernels under one release.
#
# For branch-tip builds (ref does not end in a date):
#   Takes the date from the HEAD commit instead of the tag, so the result has
#   the same shape as a tag build and orders in the same sequence.
#   Example: qcom-next @ 07f50dc44edd, committed 2026-09-04
#              -> +qcom-next-20260904-g07f50dc44edd
#   --date is required for these; pass YYYYMMDD.N to separate two branch-tip
#   builds sharing a commit date.
#
#   The caller supplies the COMMIT date rather than the build date, so that
#   rebuilding a commit reproduces its version instead of inventing a higher
#   one, and so that the date describes the source rather than when CI ran. It
#   also lands in the same space as upstream's tag dates, which track the
#   commit each tag is cut from.
#
#   The trade-off: a build date always advances, a commit date need not. If the
#   branch is ever rewound to an older commit, the next build's version goes
#   DOWN and apt will not offer it as an upgrade. That is arguably honest
#   -- older source, older version -- but it is the one case where dating by
#   the clock would behave differently.
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
#   ci/scripts/derive-localversion.sh --flavour qcom-next --ref qcom-next-7.2-rc3-20260722 --sha 07f50dc44edd
#   ci/scripts/derive-localversion.sh --flavour arduino --ref main --sha 07f50dc44edd --date 20260904
#
# Options:
#   --flavour FLAVOUR  Kernel flavour. Defaults to qcom-next.
#   --ref REF          Kernel ref (tag name or branch name). Required.
#   --sha SHA          Commit SHA, truncated to 12 hex characters. Required.
#   --date DATE        HEAD commit date as YYYYMMDD or YYYYMMDD.N. Required for
#                        branch-tip builds; ignored for dated tags, which carry
#                        their own date.
#
# Output:
#   Three KEY=VALUE lines on stdout, in GITHUB_ENV / 'set -a' form:
#
#     LOCALVERSION=+qcom-next-20260722.1-g07f50dc44edd
#     SNAPSHOT=20260722.1
#     GITSHA=07f50dc44edd
#
#   LOCALVERSION always starts with a plus. Every build carries a snapshot,
#   whether it came from the tag or from the HEAD commit.
#
# Exit codes:
#   0  Success.
#   1  Error (invalid args, malformed --sha, branch tip without --date).

FLAVOUR="qcom-next"
REF=""
SHA=""
DATE=""

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --flavour) FLAVOUR="$2"; shift 2 ;;
        --ref)     REF="$2";     shift 2 ;;
        --sha)     SHA="$2";     shift 2 ;;
        --date)    DATE="$2";    shift 2 ;;
        -h|--help) usage ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage ;;
    esac
done

[[ -n "$REF" ]] || { echo "ERROR: --ref is required" >&2; exit 1; }
[[ "$FLAVOUR" =~ ^[a-z0-9]+([a-z0-9-]*[a-z0-9])?$ ]] || {
    echo "ERROR: --flavour must use lowercase letters, digits, and internal hyphens" >&2
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
# ordinal. The matrix selects the tag set; the flavour supplies the stable
# kernel identity used in LOCALVERSION.
if [[ "$REF" =~ -([0-9]{8}(\.[0-9]+)?)$ ]]; then
    SNAPSHOT="${BASH_REMATCH[1]}"
    LOCALVERSION="+${FLAVOUR}-${SNAPSHOT}-g${GITSHA}"
else
    # Branch-tip build: the ref carries no date, so the commit date supplies
    # one. Without it these builds had no snapshot at all, which put their
    # Debian version below every dated build rather than among them.
    [[ -n "$DATE" ]] || {
        echo "ERROR: --date is required for branch-tip builds (ref '$REF' is not a dated tag)" >&2
        exit 1
    }
    [[ "$DATE" =~ ^[0-9]{8}(\.[0-9]+)?$ ]] || {
        echo "ERROR: --date must be YYYYMMDD or YYYYMMDD.N (got '$DATE')" >&2
        exit 1
    }
    SNAPSHOT="$DATE"
    LOCALVERSION="+${FLAVOUR}-${SNAPSHOT}-g${GITSHA}"
fi

echo "LOCALVERSION=${LOCALVERSION}"
echo "SNAPSHOT=${SNAPSHOT}"
echo "GITSHA=${GITSHA}"
