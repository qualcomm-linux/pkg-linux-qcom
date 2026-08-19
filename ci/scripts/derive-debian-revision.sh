#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
set -euo pipefail

# Derive the suite-specific Debian revision for one delivery leg.
#
# Formula:
#   debian_revision = stub + suite_suffix_mapping[suite] + delivery_suffix
#   delivery_suffix: Daily -> "~", Release -> ""
#
# This is the single implementation of the formula. It is called both by
# resolve-matrix.sh (once per flattened Daily/Release leg) and by
# build-kernel-deb.yml's direct-dispatch path (one suite, no full matrix
# context), so the derivation and its validation live in exactly one place.
#
# Usage:
#   ci/scripts/derive-debian-revision.sh --stub 0qli --suite trixie --delivery-type Daily
#   ci/scripts/derive-debian-revision.sh --stub 0qli --suite forky --delivery-type Release --matrix-file ci/build-matrix.json
#
# Options:
#   --stub STUB            Debian version stub. Must be non-empty and must not
#                            end in ~ (the delivery suffix supplies any
#                            trailing ~). Required.
#   --suite SUITE          Target suite; must have an entry in
#                            suite_suffix_mapping. Required.
#   --delivery-type TYPE   Daily or Release. Required.
#   --matrix-file FILE     Path to the matrix JSON containing
#                            suite_suffix_mapping
#                            (default: ci/build-matrix.json relative to CWD).
#
# Output:
#   Final Debian revision printed to stdout.
#
# Exit codes:
#   0  Success.
#   1  Error (invalid args, malformed or missing suite_suffix_mapping,
#      unmapped suite, unsupported delivery type).

STUB=""
SUITE=""
DELIVERY_TYPE=""
MATRIX_FILE="ci/build-matrix.json"

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --stub)          STUB="$2";          shift 2 ;;
        --suite)         SUITE="$2";         shift 2 ;;
        --delivery-type) DELIVERY_TYPE="$2"; shift 2 ;;
        --matrix-file)   MATRIX_FILE="$2";   shift 2 ;;
        -h|--help)       usage ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage ;;
    esac
done

[[ -n "$STUB" ]]          || { echo "ERROR: --stub is required" >&2; exit 1; }
[[ -n "$SUITE" ]]         || { echo "ERROR: --suite is required" >&2; exit 1; }
[[ -n "$DELIVERY_TYPE" ]] || { echo "ERROR: --delivery-type is required" >&2; exit 1; }
[[ "$STUB" != *"~" ]]     || { echo "ERROR: --stub must not end in ~ (got '$STUB')" >&2; exit 1; }
[[ -f "$MATRIX_FILE" ]]   || { echo "ERROR: Matrix file not found: $MATRIX_FILE" >&2; exit 1; }

jq empty "$MATRIX_FILE" 2>/dev/null \
    || { echo "ERROR: Invalid JSON in $MATRIX_FILE" >&2; exit 1; }

mapping_errors=$(jq -r '
  .suite_suffix_mapping as $mapping |
  if ($mapping | type) != "object"
  then "suite_suffix_mapping is missing or not an object"
  else
    (
      [$mapping | to_entries[] | select(.value | type != "string") | "suite_suffix_mapping[" + .key + "] must be a string"]
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
    ) | .[]
  end
' "$MATRIX_FILE")

if [[ -n "$mapping_errors" ]]; then
    echo "ERROR: Invalid suite_suffix_mapping in $MATRIX_FILE:" >&2
    while IFS= read -r error; do
        [[ -n "$error" ]] && echo "  - $error" >&2
    done <<< "$mapping_errors"
    exit 1
fi

SUFFIX=$(jq -r --arg suite "$SUITE" '.suite_suffix_mapping[$suite] // "__MISSING__"' "$MATRIX_FILE")
[[ "$SUFFIX" != "__MISSING__" ]] || {
    echo "ERROR: no suite_suffix_mapping entry for suite '$SUITE'" >&2
    exit 1
}

case "$DELIVERY_TYPE" in
    Daily)   DELIVERY_SUFFIX="~" ;;
    Release) DELIVERY_SUFFIX="" ;;
    *)
        echo "ERROR: --delivery-type must be Daily or Release (got '$DELIVERY_TYPE')" >&2
        exit 1
        ;;
esac

echo "${STUB}${SUFFIX}${DELIVERY_SUFFIX}"
