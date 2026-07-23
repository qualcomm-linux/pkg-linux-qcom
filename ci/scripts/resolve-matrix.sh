#!/bin/bash
set -euo pipefail

# Resolve and flatten the build matrix for a given build type.
#
# Reads ci/build-matrix.json, filters rows by --type, expands each row's
# 'suites' array into one flat entry per suite, and emits a compact JSON
# array to stdout suitable for use as a GitHub Actions matrix include value.
#
# Usage:
#   ci/scripts/resolve-matrix.sh --type Daily
#   ci/scripts/resolve-matrix.sh --type Release
#   ci/scripts/resolve-matrix.sh --type Daily --single-suite trixie
#   ci/scripts/resolve-matrix.sh --type Daily --matrix-file path/to/matrix.json
#
# Options:
#   --type TYPE           Build type to filter (Daily or Release). Required.
#   --single-suite SUITE  Emit only the entry for this suite (for manual
#                         workflow_dispatch single-target overrides).
#   --matrix-file FILE    Path to the matrix JSON file
#                         (default: ci/build-matrix.json relative to CWD).
#
# Output:
#   Compact JSON array to stdout, e.g.:
#   [{"type":"Daily","suite":"trixie","srcpkg":"linux-qcom-next",...},...]
#
# Exit codes:
#   0  Success, at least one entry emitted.
#   1  Error (missing args, file not found, no matching entries, invalid JSON).

TYPE=""
SINGLE_SUITE=""
MATRIX_FILE="ci/build-matrix.json"

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --type)          TYPE="$2";         shift 2 ;;
        --single-suite)  SINGLE_SUITE="$2"; shift 2 ;;
        --matrix-file)   MATRIX_FILE="$2";  shift 2 ;;
        -h|--help)       usage ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage ;;
    esac
done

[[ -n "$TYPE" ]]        || { echo "ERROR: --type is required" >&2; exit 1; }
[[ -f "$MATRIX_FILE" ]] || { echo "ERROR: Matrix file not found: $MATRIX_FILE" >&2; exit 1; }

# Validate the matrix file is valid JSON before processing.
jq empty "$MATRIX_FILE" 2>/dev/null \
    || { echo "ERROR: Invalid JSON in $MATRIX_FILE" >&2; exit 1; }

# Build the jq filter:
#   1. Filter rows where .type == TYPE.
#   2. For each row, expand .suites into one flat entry per suite.
#      If --single-suite is given, restrict to that suite only.
#   3. Each flat entry: all scalar fields from the row + "suite" key.
#   4. Error if the result is empty.
JQ_FILTER=$(cat <<'JQ'
[
  .[] |
  select(.type == $type) |
  . as $row |
  (
    if $single_suite != ""
    then
      if (.suites | map(select(. == $single_suite)) | length) > 0
      then [$single_suite]
      else []
      end
    else .suites
    end
  ) |
  .[] |
  . as $suite |
  $row | del(.suites) | . + {"suite": $suite}
] |
if length == 0
then error("no matrix entries found for type=\($type)\(if $single_suite != "" then " suite=\($single_suite)" else "" end)")
else .
end
JQ
)

result=$(jq -c \
    --arg type "$TYPE" \
    --arg single_suite "$SINGLE_SUITE" \
    "$JQ_FILTER" \
    "$MATRIX_FILE") || {
    echo "ERROR: Matrix resolution failed for type=$TYPE${SINGLE_SUITE:+ suite=$SINGLE_SUITE}" >&2
    exit 1
}

echo "$result"
