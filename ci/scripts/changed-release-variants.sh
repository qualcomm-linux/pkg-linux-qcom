#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
set -euo pipefail

# List the kernel variants whose Release row changed its branch_or_tag between
# two revisions of the delivery matrix.
#
# This is what decides which variants release.yml releases on a push to main,
# and which Release rows release-dry-run.yml builds for a pull request, so the
# rows a pull request dry-runs are exactly the rows its merge releases.
#
# Only branch_or_tag on Release rows counts. Daily rows, every other Release
# field, formatting and row order are ignored: the matrix is compared as parsed
# JSON, not as text. A Release row that exists at --head but not at --base
# counts as changed, since it names a ref that has never been released. A row
# removed at --head does not, since there is nothing left to release.
#
# Anything that prevents a reliable answer is an error rather than an empty
# result, so a broken input can never be mistaken for "nothing changed" and
# can never widen what gets released.
#
# Usage:
#   ci/scripts/changed-release-variants.sh --base REV --head REV
#   ci/scripts/changed-release-variants.sh --base REV --head REV --matrix-path ci/build-matrix.json
#
# Options:
#   --base REV           Revision to compare from. Required.
#   --head REV           Revision to compare to. Required.
#   --matrix-path PATH   Repository path of the matrix
#                          (default: ci/build-matrix.json).
#
# Output:
#   Compact JSON array of kernel_variant names on stdout, sorted, possibly
#   empty. The old and new ref of each changed variant are logged to stderr.
#
# Exit codes:
#   0  Success, including when nothing changed.
#   1  Error (invalid arguments, unknown revision, matrix missing or invalid
#      at either revision, duplicate Release rows for one variant).

BASE=""
HEAD=""
MATRIX_PATH="ci/build-matrix.json"

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --base)        BASE="${2:-}";        shift 2 ;;
        --head)        HEAD="${2:-}";        shift 2 ;;
        --matrix-path) MATRIX_PATH="${2:-}"; shift 2 ;;
        -h|--help)     usage ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage ;;
    esac
done

[[ -n "$BASE" && -n "$HEAD" ]] || {
    echo "ERROR: --base and --head are both required" >&2
    exit 1
}
[[ -n "$MATRIX_PATH" ]] || { echo "ERROR: --matrix-path must not be empty" >&2; exit 1; }

# Print the Release rows of the matrix at a revision as a
# {kernel_variant: branch_or_tag} object.
release_refs() {
    local rev=$1 commit content

    # A push that creates a branch reports an all-zero "before" SHA, and a
    # shallow clone may lack the commit entirely. Either way there is no
    # baseline to compare against, which must not read as "everything is new".
    commit=$(git rev-parse --verify --quiet "${rev}^{commit}") || {
        echo "ERROR: Not a commit in this repository: $rev" >&2
        return 1
    }
    content=$(git show "${commit}:${MATRIX_PATH}" 2>/dev/null) || {
        echo "ERROR: $MATRIX_PATH does not exist at $rev" >&2
        return 1
    }

    local refs
    refs=$(jq -c '
      if type != "object" or (.deliveries | type) != "array"
      then error("deliveries is missing or not an array")
      else [.deliveries[] | select(type == "object" and .type == "Release")]
      end
      | if any(.[]; (.kernel_variant | type) != "string" or (.kernel_variant | length) == 0)
        then error("a Release row has a missing or invalid kernel_variant")
        elif any(.[]; (.branch_or_tag | type) != "string" or (.branch_or_tag | length) == 0)
        then error("a Release row has a missing or invalid branch_or_tag")
        elif ([.[].kernel_variant] | unique | length) != length
        then error("more than one Release row for kernel_variant "
                   + ([.[].kernel_variant] | group_by(.) | map(select(length > 1)[0]) | join(", ")))
        else map({key: .kernel_variant, value: .branch_or_tag}) | from_entries
        end
    ' <<< "$content" 2>&1) || {
        echo "ERROR: $MATRIX_PATH at $rev is not a valid delivery matrix: ${refs#jq: error (at <stdin>:*): }" >&2
        return 1
    }
    echo "$refs"
}

base_refs=$(release_refs "$BASE")
head_refs=$(release_refs "$HEAD")

changed=$(jq -cn --argjson base "$base_refs" --argjson head "$head_refs" '
  [$head | to_entries[] | select($base[.key] != .value) | .key] | sort
')

jq -r --argjson base "$base_refs" --argjson head "$head_refs" '
  .[] | "Release ref changed for \(.): \($base[.] // "(new Release row)") -> \($head[.])"
' <<< "$changed" >&2

echo "$changed"
