#!/bin/bash
set -euo pipefail

# Resolve and flatten the kernel delivery matrix for a given delivery type.
#
# The matrix is flat by design: each kernel_variant owns exactly one Daily row
# and one Release row. A row declares every input needed by that delivery;
# suites are the only list-valued field and are expanded into isolated legs.
#
# Usage:
#   ci/scripts/resolve-matrix.sh --type Daily
#   ci/scripts/resolve-matrix.sh --type Release
#   ci/scripts/resolve-matrix.sh --type Daily --single-suite trixie
#   ci/scripts/resolve-matrix.sh --type Daily --kernel-variant qcom-next
#   ci/scripts/resolve-matrix.sh --type Daily --matrix-file path/to/matrix.json
#
# Options:
#   --type TYPE                Delivery type to filter (Daily or Release).
#                                Required.
#   --single-suite SUITE       Emit only entries for this suite.
#   --kernel-variant VARIANT   Emit only entries for this kernel variant.
#   --matrix-file FILE         Path to the matrix JSON file
#                                (default: ci/build-matrix.json relative to CWD).
#
# Output:
#   Compact JSON array to stdout. Every entry has a single suite and the
#   kernel_variant that scopes its artifacts, Debusine workspace, and logs.
#
# Exit codes:
#   0  Success, at least one entry emitted.
#   1  Error (invalid arguments, matrix validation failure, no matching entry).

TYPE=""
SINGLE_SUITE=""
KERNEL_VARIANT=""
MATRIX_FILE="ci/build-matrix.json"

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --type)           TYPE="$2";           shift 2 ;;
        --single-suite)   SINGLE_SUITE="$2";   shift 2 ;;
        --kernel-variant) KERNEL_VARIANT="$2"; shift 2 ;;
        --matrix-file)    MATRIX_FILE="$2";    shift 2 ;;
        -h|--help)        usage ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage ;;
    esac
done

[[ "$TYPE" == "Daily" || "$TYPE" == "Release" ]] || {
    echo "ERROR: --type must be Daily or Release" >&2
    exit 1
}
[[ -f "$MATRIX_FILE" ]] || { echo "ERROR: Matrix file not found: $MATRIX_FILE" >&2; exit 1; }

jq empty "$MATRIX_FILE" 2>/dev/null \
    || { echo "ERROR: Invalid JSON in $MATRIX_FILE" >&2; exit 1; }

validation_errors=$(jq -r '
  def required_string($field):
    if (has($field) and (.[$field] | type == "string") and (.[$field] | length > 0))
    then empty
    else "missing or invalid " + $field
    end;

  def optional_string($field):
    if (has($field) | not) or (.[$field] | type == "string")
    then empty
    else "invalid " + $field
    end;

  def variant_name_valid:
    if (.kernel_variant | type) != "string"
    then empty
    elif (.kernel_variant | test("^[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?$"))
    then empty
    else "kernel_variant must use lowercase letters, digits, and internal hyphens"
    end;

  def suites_valid:
    if (.suites | type) != "array" or (.suites | length) == 0
    then "suites must be a non-empty array"
    elif any(.suites[]; type != "string" or length == 0)
    then "suites must contain only non-empty strings"
    elif any(.suites[]; test("^[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?$") | not)
    then "suites must use lowercase letters, digits, and internal hyphens"
    elif ([.suites[]] | unique | length) != (.suites | length)
    then "suites must not contain duplicates"
    else empty
    end;

  def row_errors($index):
    if type != "object"
    then "row " + ($index | tostring) + ": matrix entries must be objects"
    else
      . as $row |
      [
        required_string("kernel_variant"),
      required_string("type"),
      required_string("git_clone"),
      required_string("branch_or_tag"),
      required_string("ref_strategy"),
      required_string("srcpkg"),
      required_string("binpkg"),
      required_string("kernel_config"),
      required_string("debian_revision"),
      optional_string("pkg_linux_qcom_ref"),
      optional_string("debusine_parent_workspace"),
      optional_string("localversion"),
      optional_string("kver_extra"),
      variant_name_valid,
      suites_valid,
      if (.type == "Daily" or .type == "Release")
      then empty else "type must be Daily or Release" end,
      if (.ref_strategy == "latest_tag" or .ref_strategy == "branch_tip" or .ref_strategy == "pinned_ref")
      then empty else "ref_strategy must be latest_tag, branch_tip, or pinned_ref" end,
      if .type == "Daily" and (.ref_strategy != "latest_tag" and .ref_strategy != "branch_tip")
      then "Daily rows must use ref_strategy=latest_tag or ref_strategy=branch_tip"
      elif .type == "Release" and .ref_strategy != "pinned_ref"
      then "Release rows must use ref_strategy=pinned_ref"
      else empty
      end,
      if .ref_strategy == "latest_tag"
      then required_string("tag_pattern")
      elif has("tag_pattern")
      then "tag_pattern is only valid with ref_strategy=latest_tag"
      else empty
      end,
      if .type == "Release"
      then required_string("target_workspace")
      elif has("target_workspace")
      then "target_workspace is only valid for Release"
      else empty
        end
      ] | .[] | "row " + ($index | tostring) + " (" + (($row.kernel_variant // "unknown") | tostring) + "): " + .
    end;

  if type != "array"
  then "matrix root must be an array"
  elif length == 0
  then "matrix must contain at least one row"
  else
    . as $matrix |
    (
      [range(0; length) as $index | $matrix[$index] | row_errors($index)]
      +
      [
        [$matrix[] | select(type == "object")]
        | group_by(.kernel_variant)
        | .[]
        | . as $rows
        | (($rows[0].kernel_variant // "unknown") | tostring) as $variant
        | ([ $rows[].type ] | sort) as $types
        | ([ $rows[].srcpkg ] | unique) as $srcpkgs
        | ([ $rows[].binpkg ] | unique) as $binpkgs
        | if ($rows | length) != 2
          then "kernel_variant " + $variant + " must define exactly one Daily row and one Release row"
          elif $types != ["Daily", "Release"]
          then "kernel_variant " + $variant + " must define exactly one Daily row and one Release row"
          elif ($srcpkgs | length) != 1
          then "kernel_variant " + $variant + " must use one srcpkg across its Daily and Release rows"
          elif ($binpkgs | length) != 1
          then "kernel_variant " + $variant + " must use one binpkg across its Daily and Release rows"
          else empty
          end
      ]
      +
      [
        [
          $matrix[]
          | select(type == "object")
          | select((.kernel_variant | type) == "string")
          | select((.srcpkg | type) == "string" and (.srcpkg | length) > 0)
          | {package: .srcpkg, kernel_variant: .kernel_variant}
        ]
        | group_by(.package)[]
        | ([.[].kernel_variant] | unique) as $variants
        | select($variants | length > 1)
        | "srcpkg " + .[0].package + " is shared by kernel variants " + ($variants | join(", "))
      ]
      +
      [
        [
          $matrix[]
          | select(type == "object")
          | select((.kernel_variant | type) == "string")
          | select((.binpkg | type) == "string" and (.binpkg | length) > 0)
          | {package: .binpkg, kernel_variant: .kernel_variant}
        ]
        | group_by(.package)[]
        | ([.[].kernel_variant] | unique) as $variants
        | select($variants | length > 1)
        | "binpkg " + .[0].package + " is shared by kernel variants " + ($variants | join(", "))
      ]
    ) | .[]
  end
' "$MATRIX_FILE")

if [[ -n "$validation_errors" ]]; then
    echo "ERROR: Invalid kernel delivery matrix:" >&2
    while IFS= read -r error; do
        [[ -n "$error" ]] && echo "  - $error" >&2
    done <<< "$validation_errors"
    exit 1
fi

result=$(jq -c \
    --arg type "$TYPE" \
    --arg single_suite "$SINGLE_SUITE" \
    --arg kernel_variant "$KERNEL_VARIANT" '
      [
        .[]
        | select(.type == $type)
        | select($kernel_variant == "" or .kernel_variant == $kernel_variant)
        | . as $row
        | (
            if $single_suite == ""
            then .suites
            elif (.suites | index($single_suite)) != null
            then [$single_suite]
            else []
            end
          )[] as $suite
        | $row | del(.suites) | . + {"suite": $suite}
      ]
      | if length == 0
        then error(
          "no matrix entries found for type=" + $type
          + (if $kernel_variant != "" then " kernel_variant=" + $kernel_variant else "" end)
          + (if $single_suite != "" then " suite=" + $single_suite else "" end)
        )
        else .
        end
    ' "$MATRIX_FILE") || {
    echo "ERROR: Matrix resolution failed for type=$TYPE${KERNEL_VARIANT:+ kernel_variant=$KERNEL_VARIANT}${SINGLE_SUITE:+ suite=$SINGLE_SUITE}" >&2
    exit 1
}

echo "$result"
