#!/bin/bash
set -euo pipefail

# Resolve and flatten the kernel delivery matrix for a given delivery type.
#
# The matrix root is an object with two top-level keys:
#   - "suite_suffix_mapping": a suite -> Debian suffix map shared by every
#     kernel variant and delivery type (e.g. "trixie": "~bpo13+1").
#   - "deliveries": the matrix rows. Each kernel_variant owns exactly one
#     Daily row and one Release row. A row declares every input needed by
#     that delivery, including a debian_version_stub; suites are the only
#     list-valued field and are expanded into isolated legs.
#
# Each flattened leg's final debian_revision is derived from
# debian_version_stub, suite_suffix_mapping[suite], and the delivery type via
# ci/scripts/derive-debian-revision.sh, so the formula has exactly one
# implementation shared with build-kernel-deb.yml's direct-dispatch path. Each
# row also carries debian_version_suffix ("~" for Daily, "" for Release) as a
# visible, validated record of that same delivery-type mapping; it is checked
# against the row's type but never fed into derivation, so a copy/paste error
# here fails fast instead of silently drifting from the formula's single
# implementation.
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
#   Compact JSON array to stdout. Every entry has a single suite, the
#   kernel_variant that scopes its artifacts, Debusine workspace, and logs,
#   and a suite-specific debian_revision (debian_version_stub and
#   debian_version_suffix are consumed and removed).
#
# Exit codes:
#   0  Success, at least one entry emitted.
#   1  Error (invalid arguments, matrix validation failure, no matching
#      entry, revision derivation failure).

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
      required_string("debian_version_stub"),
      optional_string("pkg_linux_qcom_ref"),
      optional_string("debusine_parent_workspace"),
      optional_string("localversion"),
      optional_string("kver_extra"),
      variant_name_valid,
      suites_valid,
      if (.debian_version_stub | type) == "string" and (.debian_version_stub | test("~$"))
      then "debian_version_stub must not end in ~"
      else empty end,
      if (has("debian_version_suffix") | not) or (.debian_version_suffix | type) != "string"
      then "missing or invalid debian_version_suffix"
      elif .type == "Daily" and .debian_version_suffix != "~"
      then "debian_version_suffix must be \"~\" for Daily rows (got \"" + (.debian_version_suffix | tostring) + "\")"
      elif .type == "Release" and .debian_version_suffix != ""
      then "debian_version_suffix must be \"\" for Release rows (got \"" + (.debian_version_suffix | tostring) + "\")"
      else empty end,
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

  if type != "object"
  then "matrix root must be an object with suite_suffix_mapping and deliveries"
  elif (.deliveries | type) != "array"
  then "deliveries must be an array"
  elif (.deliveries | length) == 0
  then "deliveries must contain at least one row"
  elif (.suite_suffix_mapping | type) != "object"
  then "suite_suffix_mapping is missing or not an object"
  else
    .deliveries as $matrix |
    .suite_suffix_mapping as $mapping |
    (
      [range(0; ($matrix | length)) as $index | $matrix[$index] | row_errors($index)]
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
        | ([ $rows[].debian_version_stub ] | unique) as $stubs
        | if ($rows | length) != 2
          then "kernel_variant " + $variant + " must define exactly one Daily row and one Release row"
          elif $types != ["Daily", "Release"]
          then "kernel_variant " + $variant + " must define exactly one Daily row and one Release row"
          elif ($srcpkgs | length) != 1
          then "kernel_variant " + $variant + " must use one srcpkg across its Daily and Release rows"
          elif ($binpkgs | length) != 1
          then "kernel_variant " + $variant + " must use one binpkg across its Daily and Release rows"
          elif ($stubs | length) != 1
          then "kernel_variant " + $variant + " must use one debian_version_stub across its Daily and Release rows"
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
      +
      [
        $mapping | to_entries[] | select(.value | type != "string")
        | "suite_suffix_mapping[" + .key + "] must be a string"
      ]
      +
      [
        $mapping
        | to_entries[]
        | select((.value | type == "string") and .value != "" and (.value | test("^~") | not))
        | "suite_suffix_mapping[" + .key + "] must be empty or start with ~ (got \"" + .value + "\")"
      ]
      +
      [
        $mapping
        | to_entries
        | group_by(.value)
        | map(select(length > 1))
        | .[]?
        | "suites " + ([.[].key] | join(", ")) + " share the same suffix \"" + .[0].value + "\""
      ]
      +
      [
        [$matrix[] | select(type == "object") | select((.suites | type) == "array") | .suites[]]
        | unique
        | .[] as $suite
        | select(($mapping | has($suite)) | not)
        | "suite " + $suite + " has no suite_suffix_mapping entry"
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
        .deliveries[]
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

# Derive each leg's final debian_revision from debian_version_stub,
# suite_suffix_mapping, and its delivery type. derive-debian-revision.sh is
# the single implementation of the formula; build-kernel-deb.yml's direct
# dispatch path calls the same script for the one-suite, no-matrix case.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

final="[]"
while IFS= read -r leg; do
    suite=$(jq -r '.suite' <<< "$leg")
    stub=$(jq -r '.debian_version_stub' <<< "$leg")
    delivery_type=$(jq -r '.type' <<< "$leg")
    variant=$(jq -r '.kernel_variant' <<< "$leg")

    revision=$("$script_dir/derive-debian-revision.sh" \
        --stub "$stub" --suite "$suite" --delivery-type "$delivery_type" \
        --matrix-file "$MATRIX_FILE") || {
        echo "ERROR: Failed to derive Debian revision for kernel_variant=$variant suite=$suite type=$delivery_type" >&2
        exit 1
    }

    leg=$(jq -c --arg rev "$revision" '(. + {debian_revision: $rev}) | del(.debian_version_stub, .debian_version_suffix)' <<< "$leg")
    final=$(jq -c --argjson leg "$leg" '. + [$leg]' <<< "$final")
done < <(jq -c '.[]' <<< "$result")

echo "$final"
