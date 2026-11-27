#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
set -euo pipefail

# List the Release legs (kernel variant and suite) whose version changed
# between two revisions of the delivery matrix.
#
# This is what decides which variants release.yml releases on a push to main,
# and which Release legs release-dry-run.yml builds for a pull request, so the
# legs a pull request dry-runs are exactly the legs its merge releases.
#
# A release has to carry a version the target workspace has not seen, so only
# a change to the version releases. For a Release row that is:
#
#   - branch_or_tag, the upstream part of the version, or
#     debian_version_stub, the Debian revision. Either changes the version of
#     every suite of the row;
#   - suite_suffix_mapping for one of the row's suites, which the revision of
#     that suite's leg is derived from. This changes the version of that
#     suite only. Adding a suite counts, since that suite has never had this
#     version.
#
# Only the legs whose version changed are listed. The other suites of the row
# keep the version already released, and releasing them again would collide
# with it. Daily rows, every other Release field, removed suites, formatting
# and row order are ignored: the matrix is compared as parsed JSON, not as
# text. A Release row that exists at --head but not at --base counts as
# changed in every suite, since it names a version that has never been
# released. A row removed at --head does not, since there is nothing left to
# release.
#
# With --unreleased it lists the opposite instead: Release rows that changed
# while the version of none of their suites did, which therefore release
# nothing. Those are the
# changes a reviewer most needs to hear about, since they look like they
# should ship and can't until the version is bumped.
#
# Anything that prevents a reliable answer is an error rather than an empty
# result, so a broken input can never be mistaken for "nothing changed" and
# can never widen what gets released.
#
# Usage:
#   ci/scripts/changed-release-variants.sh --base REV --head REV
#   ci/scripts/changed-release-variants.sh --base REV --head REV --matrix-path ci/build-matrix.json
#   ci/scripts/changed-release-variants.sh --base REV --head REV --unreleased
#
# Options:
#   --base REV           Revision to compare from. Required.
#   --head REV           Revision to compare to. Required.
#   --matrix-path PATH   Repository path of the matrix
#                          (default: ci/build-matrix.json).
#   --unreleased         List the Release rows that changed without a
#                          version change, instead of the legs to release.
#
# Output:
#   Compact JSON array on stdout, sorted, possibly empty, with one
#   {"kernel_variant": ..., "suite": ...} object for each leg to release.
#   What changed in each variant's version is logged to stderr.
#
#   With --unreleased, a compact JSON object on stdout instead, possibly
#   empty, mapping each such kernel_variant to the sorted names of the Release
#   row fields that changed, e.g. {"qcom-7.3-debug":["dkms"]}.
#
# Exit codes:
#   0  Success, including when nothing changed.
#   1  Error (invalid arguments, unknown revision, matrix missing or invalid
#      at either revision, duplicate Release rows for one variant, a Release
#      suite with no suite_suffix_mapping entry).

BASE=""
HEAD=""
MATRIX_PATH="ci/build-matrix.json"
UNRELEASED=false

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --base)        BASE="${2:-}";        shift 2 ;;
        --head)        HEAD="${2:-}";        shift 2 ;;
        --matrix-path) MATRIX_PATH="${2:-}"; shift 2 ;;
        --unreleased)  UNRELEASED=true;      shift ;;
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
# {kernel_variant: {row: <Release row>, suffixes: {suite: suffix}}} object,
# where suffixes holds the suite_suffix_mapping entry of each of the row's
# suites.
release_rows() {
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

    local rows
    rows=$(jq -c '
      def nonempty_string: type == "string" and length > 0;
      if type != "object" or (.deliveries | type) != "array"
      then error("deliveries is missing or not an array")
      elif (.suite_suffix_mapping | type) != "object"
      then error("suite_suffix_mapping is missing or not an object")
      else .suite_suffix_mapping as $mapping
      | [.deliveries[] | select(type == "object" and .type == "Release")]
      | if any(.[]; .kernel_variant | nonempty_string | not)
        then error("a Release row has a missing or invalid kernel_variant")
        elif any(.[]; .branch_or_tag | nonempty_string | not)
        then error("a Release row has a missing or invalid branch_or_tag")
        elif any(.[]; .debian_version_stub | nonempty_string | not)
        then error("a Release row has a missing or invalid debian_version_stub")
        elif any(.[]; (.suites | type) != "array" or any(.suites[]; nonempty_string | not))
        then error("a Release row has a missing or invalid suites list")
        elif any(.[]; any(.suites[]; in($mapping) | not))
        then error("a Release suite has no suite_suffix_mapping entry")
        elif ([.[].kernel_variant] | unique | length) != length
        then error("more than one Release row for kernel_variant "
                   + ([.[].kernel_variant] | group_by(.) | map(select(length > 1)[0]) | join(", ")))
        else map({key: .kernel_variant,
                  value: {row: ., suffixes: (. as $row | [$row.suites[] | {key: ., value: $mapping[.]}] | from_entries)}})
             | from_entries
        end
      end
    ' <<< "$content" 2>&1) || {
        echo "ERROR: $MATRIX_PATH at $rev is not a valid delivery matrix: ${rows#jq: error (at <stdin>:*): }" >&2
        return 1
    }
    echo "$rows"
}

base_rows=$(release_rows "$BASE")
head_rows=$(release_rows "$HEAD")

# For each Release variant at --head, why its version is new and in which
# suites: {reasons: [...], suites: [...]}, both empty when it is the version
# already released. branch_or_tag and debian_version_stub are part of every
# suite's version, so changing either releases every suite. A suffix is part
# of one suite's version only, so changing it releases that suite alone.
version_changes=$(jq -cn --argjson base "$base_rows" --argjson head "$head_rows" '
  def changes($old; $new):
    if $old == null
    then {reasons: ["new Release row"], suites: $new.row.suites}
    else
      [ ("branch_or_tag", "debian_version_stub")
        | select($old.row[.] != $new.row[.])
        | "\(.) \($old.row[.]) -> \($new.row[.])" ] as $row
      | [ $new.suffixes | to_entries[]
          | . as $leg
          | if $old.suffixes | has($leg.key) | not
            then {suite: .key, reason: "new suite \(.key)"}
            elif $old.suffixes[.key] != .value
            then {suite: .key,
                  reason: "suite \(.key) suffix \"\($old.suffixes[.key])\" -> \"\(.value)\""}
            else empty end ] as $suffix
      | {reasons: ($row + [$suffix[].reason]),
         suites: (if $row != [] then $new.row.suites else [$suffix[].suite] end)}
    end;
  $head | with_entries(.value = changes($base[.key]; .value))
')

if [[ "$UNRELEASED" == true ]]; then
    # Rows present at both revisions whose version is the one already
    # released, but which differ as parsed JSON, so key order doesn't count.
    jq -cnS --argjson base "$base_rows" --argjson head "$head_rows" \
           --argjson changes "$version_changes" '
      [ $head | to_entries[]
        | .key as $variant
        | select($base | has($variant)) | select($changes[$variant].reasons == [])
        | $base[$variant].row as $old | .value.row as $new
        | [ ($old + $new) | keys[] | select($old[.] != $new[.]) ] as $fields
        | select($fields != [])
        | {key: $variant, value: $fields} ]
      | from_entries
    '
    exit 0
fi

jq -r 'to_entries[] | select(.value.reasons | length > 0)
  | "Release version changed for \(.key): \(.value.reasons | join(", "))"' <<< "$version_changes" >&2

jq -c '[to_entries[] | .key as $variant | .value.suites[]
        | {kernel_variant: $variant, suite: .}]
       | sort_by([.kernel_variant, .suite])' <<< "$version_changes"
