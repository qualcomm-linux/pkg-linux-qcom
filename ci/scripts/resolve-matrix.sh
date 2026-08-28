#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
set -euo pipefail

# Resolve and flatten the kernel delivery matrix.
#
# The matrix root is an object with two top-level keys:
#   - "suite_suffix_mapping": a suite -> Debian suffix map shared by every
#     kernel variant and delivery type (e.g. "trixie": "~bpo13+1").
#   - "variants": the matrix rows, one per variant. Every delivery is
#     the same kind of thing — resolve the row's ref at run time from its
#     latest_tag or branch_tip strategy, build it, and promote it to
#     target_workspace if the build passes — so a row needs no delivery type to
#     distinguish it. A matrix row is a standing description of what to track,
#     never a record of one chosen commit. A row declares every input needed by
#     that delivery, including a debian_version_stub. Two fields are
#     list-valued: suites, which is expanded into isolated legs, and
#     kernel_config, which is one config fragment per element.
#
# Each flattened leg's final debian_revision is derived from
# debian_version_stub and suite_suffix_mapping[suite] via
# ci/scripts/derive-debian-revision.sh, so the formula has exactly one
# implementation shared with build-kernel-deb.yml's direct-dispatch path.
#
# Usage:
#   ci/scripts/resolve-matrix.sh
#   ci/scripts/resolve-matrix.sh --single-suite trixie
#   ci/scripts/resolve-matrix.sh --kernel-variant qcom-next
#   ci/scripts/resolve-matrix.sh --matrix-file path/to/matrix.json
#
# Options:
#   --single-suite SUITE       Emit only entries for this suite.
#   --kernel-variant VARIANT   Emit only entries for this kernel variant.
#   --matrix-file FILE         Path to the matrix JSON file
#                                (default: ci/build-matrix.json relative to CWD).
#
# Output:
#   Compact JSON array to stdout. Every entry has a single suite, the
#   variant that scopes its artifacts, Debusine workspace, and logs,
#   and a suite-specific debian_revision (debian_version_stub is consumed and
#   removed). kernel_config is joined
#   into the comma-separated string that build-kernel-deb.yml's kernel-config
#   input and prepare-source.sh's --kernel-config expect.
#
# Exit codes:
#   0  Success, at least one entry emitted.
#   1  Error (invalid arguments, matrix validation failure, no matching
#      entry, revision derivation failure).

SINGLE_SUITE=""
KERNEL_VARIANT=""
MATRIX_FILE="ci/build-matrix.json"

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --single-suite)   SINGLE_SUITE="$2";   shift 2 ;;
        --kernel-variant) KERNEL_VARIANT="$2"; shift 2 ;;
        --matrix-file)    MATRIX_FILE="$2";    shift 2 ;;
        -h|--help)        usage ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage ;;
    esac
done

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
    if (.variant | type) != "string"
    then empty
    elif (.variant | test("^[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?$"))
    then empty
    else "variant must use lowercase letters, digits, and internal hyphens"
    end;

  def kernel_config_valid:
    if (.kernel_config | type) != "array"
    then "kernel_config must be an array"
    elif any(.kernel_config[]; type != "string" or length == 0)
    then "kernel_config must contain only non-empty strings"
    elif any(.kernel_config[]; test(","))
    then "kernel_config entries must not contain commas; use one array element per fragment"
    elif ([.kernel_config[]] | unique | length) != (.kernel_config | length)
    then "kernel_config must not contain duplicates"
    else empty
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
        required_string("variant"),
      required_string("git_clone"),
      required_string("branch_or_tag"),
      required_string("ref_strategy"),
      required_string("srcpkg"),
      required_string("binpkg"),
      required_string("debian_version_stub"),
      required_string("target_workspace"),
      optional_string("pkg_linux_qcom_ref"),
      optional_string("debusine_parent_workspace"),
      optional_string("localversion"),
      optional_string("kver_extra"),
      variant_name_valid,
      suites_valid,
      kernel_config_valid,
      if (.debian_version_stub | type) == "string" and (.debian_version_stub | test("~$"))
      then "debian_version_stub must not end in ~"
      else empty end,
      if (.ref_strategy == "latest_tag" or .ref_strategy == "branch_tip")
      then empty
      else "ref_strategy must be latest_tag or branch_tip; every delivery resolves its ref at run time"
      end,
      if .ref_strategy == "latest_tag"
      then required_string("tag_pattern")
      elif has("tag_pattern")
      then "tag_pattern is only valid with ref_strategy=latest_tag"
      else empty
        end
      ] | .[] | "row " + ($index | tostring) + " (" + (($row.variant // "unknown") | tostring) + "): " + .
    end;

  if type != "object"
  then "matrix root must be an object with suite_suffix_mapping and variants"
  elif (.variants | type) != "array"
  then "variants must be an array"
  elif (.variants | length) == 0
  then "variants must contain at least one row"
  elif (.suite_suffix_mapping | type) != "object"
  then "suite_suffix_mapping is missing or not an object"
  else
    .variants as $matrix |
    .suite_suffix_mapping as $mapping |
    (
      [range(0; ($matrix | length)) as $index | $matrix[$index] | row_errors($index)]
      +
      [
        [$matrix[] | select(type == "object")]
        | group_by(.variant)
        | .[]
        | . as $rows
        | (($rows[0].variant // "unknown") | tostring) as $variant
        | if ($rows | length) != 1
          then "variant " + $variant + " is defined by "
               + ($rows | length | tostring)
               + " rows; each variant is one delivery and must appear once"
          else empty
          end
      ]
      +
      [
        [
          $matrix[]
          | select(type == "object")
          | select((.variant | type) == "string")
          | select((.srcpkg | type) == "string" and (.srcpkg | length) > 0)
          | {package: .srcpkg, variant: .variant}
        ]
        | group_by(.package)[]
        | ([.[].variant] | unique) as $variants
        | select($variants | length > 1)
        | "srcpkg " + .[0].package + " is shared by kernel variants " + ($variants | join(", "))
      ]
      +
      [
        [
          $matrix[]
          | select(type == "object")
          | select((.variant | type) == "string")
          | select((.binpkg | type) == "string" and (.binpkg | length) > 0)
          | {package: .binpkg, variant: .variant}
        ]
        | group_by(.package)[]
        | ([.[].variant] | unique) as $variants
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
    --arg single_suite "$SINGLE_SUITE" \
    --arg variant "$KERNEL_VARIANT" '
      [
        .variants[]
        | select($variant == "" or .variant == $variant)
        | . as $row
        | (
            if $single_suite == ""
            then .suites
            elif (.suites | index($single_suite)) != null
            then [$single_suite]
            else []
            end
          )[] as $suite
        | $row
        | del(.suites)
        | . + {"suite": $suite, "kernel_config": ($row.kernel_config | join(","))}
      ]
      | if length == 0
        then error(
          "no matrix entries found"
          + (if $variant != "" then " for variant=" + $variant else "" end)
          + (if $single_suite != "" then " suite=" + $single_suite else "" end)
        )
        else .
        end
    ' "$MATRIX_FILE") || {
    echo "ERROR: Matrix resolution failed${KERNEL_VARIANT:+ for variant=$KERNEL_VARIANT}${SINGLE_SUITE:+ suite=$SINGLE_SUITE}" >&2
    exit 1
}

# Derive each leg's final debian_revision from debian_version_stub and
# suite_suffix_mapping. derive-debian-revision.sh is the single implementation
# of the formula; build-kernel-deb.yml's direct dispatch path calls the same
# script for the one-suite, no-matrix case.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

final="[]"
while IFS= read -r leg; do
    suite=$(jq -r '.suite' <<< "$leg")
    stub=$(jq -r '.debian_version_stub' <<< "$leg")
    variant=$(jq -r '.variant' <<< "$leg")

    revision=$("$script_dir/derive-debian-revision.sh" \
        --stub "$stub" --suite "$suite" \
        --matrix-file "$MATRIX_FILE") || {
        echo "ERROR: Failed to derive Debian revision for variant=$variant suite=$suite" >&2
        exit 1
    }

    leg=$(jq -c --arg rev "$revision" '(. + {debian_revision: $rev}) | del(.debian_version_stub)' <<< "$leg")
    final=$(jq -c --argjson leg "$leg" '. + [$leg]' <<< "$final")
done < <(jq -c '.[]' <<< "$result")

echo "$final"
