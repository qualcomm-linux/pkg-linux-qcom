#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
set -euo pipefail

# bundle-dkms-modules.sh — Build and bundle out-of-tree DKMS modules into the
# linux-image staging tree at dpkg-buildpackage time.
#
# This script is the single source of truth for DKMS module integration.
# It is called by debian/rules override_dh_auto_install after the kernel image,
# modules, headers, and debug packages have been staged, and can also be invoked
# directly by a developer who has already staged those trees manually.
#
# What it does (for each module listed in the manifest):
#   1. Resolves the installed -dkms package via dpkg -L (authoritative, no globbing).
#   2. Reads PACKAGE_NAME / PACKAGE_VERSION from the package's dkms.conf.
#   3. Builds the module with `dkms build` against the staged kernel headers,
#      using a private --dkmstree (mktemp) to avoid writing to /var/lib/dkms/.
#   4. Judges the outcome by artifact presence, not dkms exit code.
#      On failure: prints make.log tail (build failure) or BUILD_EXCLUSIVE gate
#      analysis (skip), then hard-fails — a manifest entry is a presence contract.
#   5. For each produced .ko:
#      - Collision-checks against already-bundled modules and in-tree modules.
#      - Installs to <image-pkg-dir>/lib/modules/<kver>/extra/<name>.ko
#      - Extracts debug symbols to <dbg-pkg-dir>/usr/lib/debug/lib/modules/<kver>/extra/<name>.ko
#        via objcopy --only-keep-debug (Stage 1, non-destructive).
#      - Strips the shipped copy with `strip --strip-debug` (Stage 2).
#        --strip-debug is required for kernel modules: a full strip drops the
#        symtab and relocations needed by the module loader.
#
# PREREQUISITES (must be satisfied before calling this script):
#   - The kernel image staging tree must exist at --image-pkg-dir with:
#       lib/modules/<kver>/kernel/   (in-tree modules, for collision detection)
#       boot/config-<kver>           (kernel .config, for BUILD_EXCLUSIVE_CONFIG checks)
#   - The debug package staging tree must exist at --dbg-pkg-dir.
#   - The kernel headers must be fully staged at --headers-dir (absolute path).
#     This is the directory containing Makefile, include/, scripts/, arch/, etc.
#     It must be an absolute path: dkms invokes make from inside the module
#     source directory, so a relative path would resolve to nothing from there.
#   - Each module listed in the manifest must have its -dkms package installed
#     in the build environment (declared as Build-Depends in debian/control.in).
#
# USAGE (from debian/rules — CI path):
#   debian/scripts/bundle-dkms-modules.sh \
#     --kver        "$BASE" \
#     --headers-dir "$(CURDIR)/debian/linux-headers-$BASE-qcom/usr/src/linux-headers-$BASE" \
#     --image-pkg-dir "$(CURDIR)/debian/linux-image-$BASE-qcom" \
#     --dbg-pkg-dir   "$(CURDIR)/debian/linux-image-$BASE-qcom-dbg" \
#     --arch          "$(DKMS_ARCH)" \
#     --objcopy       "$(OBJCOPY)" \
#     --modules-manifest "$(CURDIR)/debian/dkms-modules"
#
# USAGE (standalone developer path — after manual staging):
#   debian/scripts/bundle-dkms-modules.sh \
#     --kver        6.12.0-qcom-next-20260210 \
#     --headers-dir /path/to/kernel-source/debian/linux-headers-6.12.0-qcom-next-20260210-qcom/usr/src/linux-headers-6.12.0-qcom-next-20260210 \
#     --image-pkg-dir /path/to/kernel-source/debian/linux-image-6.12.0-qcom-next-20260210-qcom \
#     --dbg-pkg-dir   /path/to/kernel-source/debian/linux-image-6.12.0-qcom-next-20260210-qcom-dbg

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Internal: DKMS source root prefix used when resolving dkms.conf paths from
# dpkg -L output. Defaults to /usr/src (production). Can be overridden via
# environment variable _BUNDLE_DKMS_SRC_ROOT for testing purposes only.
# ---------------------------------------------------------------------------
_DKMS_SRC_ROOT="${_BUNDLE_DKMS_SRC_ROOT:-/usr/src}"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
KVER=""
HEADERS_DIR=""
IMAGE_PKG_DIR=""
DBG_PKG_DIR=""
# Default manifest: debian/dkms-modules (one level up from debian/scripts/)
MODULES_MANIFEST="${SCRIPT_DIR}/../dkms-modules"
# dkms --arch speaks uname -m vocabulary (aarch64), not kbuild vocabulary (arm64).
# This matters for dkms.conf BUILD_EXCLUSIVE_ARCH gates.
DKMS_ARCH="aarch64"
# objcopy: prefer the aarch64 cross-compiler's objcopy; fall back to host objcopy.
OBJCOPY="$(which aarch64-linux-gnu-objcopy 2>/dev/null || which objcopy 2>/dev/null || echo objcopy)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[bundle-dkms]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[bundle-dkms]${NC} $*"; }
log_error() { echo -e "${RED}[bundle-dkms]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[bundle-dkms]${NC} $*"; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build and bundle out-of-tree DKMS modules into the linux-image staging tree.

Called by debian/rules at dpkg-buildpackage time (CI path), and can also be
invoked directly by a developer who has already staged the kernel trees.

REQUIRED:
  --kver KVER               Kernel release string (uname -r), e.g.:
                              6.12.0-qcom-next-20260210
  --headers-dir DIR         Absolute path to the staged kernel headers root.
                            Must contain Makefile, include/, scripts/, arch/.
                            MUST be absolute: dkms invokes make from inside the
                            module source directory, so a relative path fails.
                            In debian/rules this is:
                              \$(CURDIR)/debian/linux-headers-\$BASE-qcom/usr/src/linux-headers-\$BASE
  --image-pkg-dir DIR       Path to the linux-image staging tree root.
                            .ko files are installed under:
                              <image-pkg-dir>/lib/modules/<kver>/extra/
                            In debian/rules this is:
                              \$(CURDIR)/debian/linux-image-\$BASE-qcom
  --dbg-pkg-dir DIR         Path to the debug package staging tree root.
                            Debug symbols are installed under:
                              <dbg-pkg-dir>/usr/lib/debug/lib/modules/<kver>/extra/
                            In debian/rules this is:
                              \$(CURDIR)/debian/linux-image-\$BASE-qcom-dbg

OPTIONAL:
  --modules-manifest FILE   Path to the dkms-modules manifest.
                            Default: debian/dkms-modules (relative to this script's
                            location, i.e. \$(dirname \$0)/../dkms-modules).
  --arch ARCH               Architecture token in uname -m vocabulary passed to
                            dkms --arch and used for BUILD_EXCLUSIVE_ARCH matching.
                            Default: aarch64
  --objcopy PATH            Path to objcopy binary for debug symbol extraction.
                            Default: aarch64-linux-gnu-objcopy, then objcopy.
  -h, --help                Show this help and exit.

PREREQUISITES (developer standalone use):
  1. The -dkms package for each module in the manifest must be installed.
  2. --headers-dir must point to a fully staged kernel headers tree.
  3. --image-pkg-dir must contain lib/modules/<kver>/kernel/ (in-tree modules)
     and boot/config-<kver> (kernel .config).
  4. --dbg-pkg-dir must exist (can be empty; subdirs are created as needed).
  5. --headers-dir must be an absolute path.

MANIFEST FORMAT (debian/dkms-modules):
  One module name per line (without the -dkms suffix).
  Lines starting with # and blank lines are ignored.
  A corresponding Build-Depends entry must exist in debian/control.in.

EXAMPLES:
  # CI path (called from debian/rules):
  debian/scripts/bundle-dkms-modules.sh \\
    --kver 6.12.0-qcom-next-20260210 \\
    --headers-dir /build/kernel/debian/linux-headers-6.12.0-qcom-next-20260210-qcom/usr/src/linux-headers-6.12.0-qcom-next-20260210 \\
    --image-pkg-dir /build/kernel/debian/linux-image-6.12.0-qcom-next-20260210-qcom \\
    --dbg-pkg-dir   /build/kernel/debian/linux-image-6.12.0-qcom-next-20260210-qcom-dbg

  # Developer standalone path:
  debian/scripts/bundle-dkms-modules.sh \\
    --kver 6.12.0-qcom-next-20260210 \\
    --headers-dir /path/to/staged/linux-headers-6.12.0-qcom-next-20260210 \\
    --image-pkg-dir /path/to/staged/linux-image-6.12.0-qcom-next-20260210-qcom \\
    --dbg-pkg-dir   /path/to/staged/linux-image-6.12.0-qcom-next-20260210-qcom-dbg \\
    --arch aarch64

  # With explicit manifest and objcopy:
  debian/scripts/bundle-dkms-modules.sh \\
    --kver 6.12.0-qcom-next-20260210 \\
    --headers-dir /path/to/headers \\
    --image-pkg-dir /path/to/image-pkg \\
    --dbg-pkg-dir   /path/to/dbg-pkg \\
    --modules-manifest /path/to/debian/dkms-modules \\
    --objcopy aarch64-linux-gnu-objcopy
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --kver)              KVER="$2";              shift 2 ;;
        --headers-dir)       HEADERS_DIR="$2";       shift 2 ;;
        --image-pkg-dir)     IMAGE_PKG_DIR="$2";     shift 2 ;;
        --dbg-pkg-dir)       DBG_PKG_DIR="$2";       shift 2 ;;
        --modules-manifest)  MODULES_MANIFEST="$2";  shift 2 ;;
        --arch)              DKMS_ARCH="$2";         shift 2 ;;
        --objcopy)           OBJCOPY="$2";           shift 2 ;;
        -h|--help)           usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate required arguments
# ---------------------------------------------------------------------------
_missing=()
[[ -n "$KVER"          ]] || _missing+=(--kver)
[[ -n "$HEADERS_DIR"   ]] || _missing+=(--headers-dir)
[[ -n "$IMAGE_PKG_DIR" ]] || _missing+=(--image-pkg-dir)
[[ -n "$DBG_PKG_DIR"   ]] || _missing+=(--dbg-pkg-dir)
if [[ ${#_missing[@]} -gt 0 ]]; then
    log_error "Missing required arguments: ${_missing[*]}"
    log_error "Run with --help for usage."
    exit 1
fi

# --headers-dir must be absolute (dkms invokes make from inside the module
# source directory, so a relative path resolves to nothing from there).
[[ "$HEADERS_DIR" == /* ]] || {
    log_error "--headers-dir must be an absolute path (got: $HEADERS_DIR)"
    log_error "dkms invokes make from inside the module source directory;"
    log_error "a relative path would resolve to nothing from that location."
    exit 1
}

# ---------------------------------------------------------------------------
# Read and parse the manifest
# ---------------------------------------------------------------------------
# A missing manifest is a misconfiguration, not an empty module set: fail
# loudly rather than silently shipping a kernel without its declared modules
# (the manifest is a presence contract). An existing-but-empty or comment-only
# manifest is a legitimate "no modules" and skips below.
if [[ ! -f "$MODULES_MANIFEST" ]]; then
    log_error "Modules manifest not found: $MODULES_MANIFEST"
    log_error "Pass --modules-manifest <file>, or create debian/dkms-modules."
    exit 1
fi

# Resolve manifest path to absolute (so it works regardless of cwd). Safe to
# drop the cd error-suppression here: the file is confirmed to exist above, so
# its parent directory exists and the cd cannot fail.
MODULES_MANIFEST="$(cd "$(dirname "$MODULES_MANIFEST")" && pwd)/$(basename "$MODULES_MANIFEST")"

# Strip comments (# to end of line), blank lines, and CR line endings.
# Result is a space-separated list of module names.
DKMS_MODULES="$(sed -e 's/#.*//' -e 's/\r$//' "$MODULES_MANIFEST" \
                | tr -s ' \t\n' ' ' | sed 's/^ //;s/ $//')"

if [[ -z "$DKMS_MODULES" ]]; then
    log_info "Manifest $MODULES_MANIFEST lists no modules; nothing to bundle."
    exit 0
fi

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
[[ -d "$HEADERS_DIR" ]] || {
    log_error "--headers-dir does not exist: $HEADERS_DIR"
    log_error "The kernel headers must be staged before calling this script."
    exit 1
}
[[ -d "$IMAGE_PKG_DIR" ]] || {
    log_error "--image-pkg-dir does not exist: $IMAGE_PKG_DIR"
    log_error "The linux-image staging tree must exist before calling this script."
    exit 1
}
if [[ ! -d "$DBG_PKG_DIR" ]]; then
    log_warn "--dbg-pkg-dir does not exist: $DBG_PKG_DIR (will be created as needed)"
fi

log_step "DKMS module bundling configuration:"
log_info "  kver:             $KVER"
log_info "  headers-dir:      $HEADERS_DIR"
log_info "  image-pkg-dir:    $IMAGE_PKG_DIR"
log_info "  dbg-pkg-dir:      $DBG_PKG_DIR"
log_info "  modules-manifest: $MODULES_MANIFEST"
log_info "  arch:             $DKMS_ARCH"
log_info "  objcopy:          $OBJCOPY"
log_info "  modules:          $DKMS_MODULES"
echo

# ---------------------------------------------------------------------------
# Private DKMS tree — redirects artifacts away from /var/lib/dkms/ (root-owned,
# not writable under fakeroot / non-root dpkg-buildpackage).
# Shared across all modules in this run; cleaned up on EXIT.
# ---------------------------------------------------------------------------
DKMS_TREE="$(mktemp -d)"
trap 'rm -rf "$DKMS_TREE"' EXIT

# ---------------------------------------------------------------------------
# Main loop: build and bundle each listed module
# ---------------------------------------------------------------------------
for name in $DKMS_MODULES; do

    log_step "Processing DKMS module: $name"

    # ── Resolve the module from the package manager ──────────────────────────
    # dpkg -L <name>-dkms is authoritative: the -dkms package ships exactly one
    # <_DKMS_SRC_ROOT>/<dir>/dkms.conf (dh_dkms layout), so the source tree is
    # found without guessing and a look-alike directory from another package can
    # never be picked up.
    conf="$(dpkg -L "${name}-dkms" 2>/dev/null \
            | grep -E "^${_DKMS_SRC_ROOT}/[^/]+/dkms\\.conf\$" || true)"

    if [[ -z "$conf" ]]; then
        log_error "${name}-dkms is not installed or ships no ${_DKMS_SRC_ROOT}/<dir>/dkms.conf"
        log_error "Is ${name}-dkms declared in Build-Depends in debian/control.in?"
        exit 1
    fi

    conf_count="$(printf '%s\n' "$conf" | wc -l)"
    if [[ "$conf_count" -ne 1 ]]; then
        log_error "${name}-dkms ships multiple dkms.conf files (expected exactly 1):"
        printf '%s\n' "$conf" >&2
        exit 1
    fi

    SRC="${conf%/dkms.conf}"

    # ── Read PACKAGE_NAME / PACKAGE_VERSION from dkms.conf ───────────────────
    # dkms.conf is the authority on the name/version tokens that drive the dkms
    # tree layout and the build call. Values are read literally, as installed by
    # dh_dkms. The `tail -1` handles the (unusual) case of duplicate keys.
    PKG_NAME="$(sed -n 's/^[[:space:]]*PACKAGE_NAME=//p' "$conf" | tail -1 | tr -d '"')"
    PKG_VER="$(sed -n  's/^[[:space:]]*PACKAGE_VERSION=//p' "$conf" | tail -1 | tr -d '"')"

    if [[ -z "$PKG_NAME" || -z "$PKG_VER" ]]; then
        log_error "PACKAGE_NAME or PACKAGE_VERSION not found in $conf"
        exit 1
    fi

    # ── Guard against duplicate manifest entries resolving to the same module ─
    if [[ -e "$DKMS_TREE/$PKG_NAME/$PKG_VER" ]]; then
        log_error "Duplicate dkms module $PKG_NAME/$PKG_VER"
        log_error "Already prepared by an earlier manifest entry — check $MODULES_MANIFEST"
        exit 1
    fi

    # ── Set up the private DKMS tree layout ──────────────────────────────────
    # dkms expects: <dkmstree>/<name>/<ver>/source -> <actual source dir>
    mkdir -p "$DKMS_TREE/$PKG_NAME/$PKG_VER"
    ln -sf "$SRC" "$DKMS_TREE/$PKG_NAME/$PKG_VER/source"

    log_info "Building DKMS module $PKG_NAME/$PKG_VER for $KVER"
    log_info "  source:          $SRC"
    log_info "  kernelsourcedir: $HEADERS_DIR"
    log_info "  dkmstree:        $DKMS_TREE"

    # ── Run dkms build ────────────────────────────────────────────────────────
    # Capture exit code separately: dkms exit-code conventions vary across
    # versions (a BUILD_EXCLUSIVE skip can exit 0). Outcome is judged by
    # artifact presence, not exit code.
    dkms_rc=0
    dkms build "$PKG_NAME/$PKG_VER" \
        --kernelsourcedir "$HEADERS_DIR" \
        --dkmstree        "$DKMS_TREE" \
        -k                "$KVER" \
        --arch            "$DKMS_ARCH" \
        || dkms_rc=$?

    # ── Judge outcome by artifacts ────────────────────────────────────────────
    # A .ko under <tree>/<name>/<ver>/<kver>/ means success.
    # dkms's make.log separates the two failure modes:
    #   - make.log present  → build was attempted and failed
    #   - no make.log       → dkms attempted no build (BUILD_EXCLUSIVE gate)
    # The log is printed inline because the private dkms tree is deleted on
    # EXIT, so it is the only surviving record in CI.
    kos="$(find "$DKMS_TREE/$PKG_NAME/$PKG_VER/$KVER" -name '*.ko' 2>/dev/null || true)"

    if [[ "$dkms_rc" -ne 0 || -z "$kos" ]]; then
        mklog="$(find "$DKMS_TREE/$PKG_NAME/$PKG_VER" -name make.log 2>/dev/null \
                 | head -1 || true)"
        if [[ -n "$mklog" ]]; then
            log_error "dkms build failed for $PKG_NAME/$PKG_VER on kernel $KVER (dkms exit $dkms_rc); make.log tail:"
            tail -n 300 "$mklog" | sed 's/^/  | /' >&2
        else
            log_error "$PKG_NAME/$PKG_VER produced no module for kernel $KVER; dkms attempted no build (dkms exit $dkms_rc)."
            gates="$(grep -E '^[[:space:]]*BUILD_EXCLUSIVE' "$conf" 2>/dev/null || true)"
            if [[ -n "$gates" ]]; then
                echo "  BUILD_EXCLUSIVE gates declared by $conf:" >&2
                printf '%s\n' "$gates" | sed 's/^[[:space:]]*/  | /' >&2
                # Evaluate each BUILD_EXCLUSIVE_CONFIG against the staged kernel .config
                kernel_config="$IMAGE_PKG_DIR/boot/config-$KVER"
                while IFS= read -r gate_line; do
                    c="$(printf '%s\n' "$gate_line" \
                         | sed -n 's/^[[:space:]]*BUILD_EXCLUSIVE_CONFIG=//p' \
                         | tr -d '"')"
                    [[ -n "$c" ]] || continue
                    if grep -q "^${c}=[ym]" "$kernel_config" 2>/dev/null; then
                        echo "  | $c is set in this kernel's config" >&2
                    else
                        echo "  | $c is NOT set in this kernel's config" >&2
                    fi
                done <<< "$gates"
                echo "  This kernel: $KVER, dkms arch $DKMS_ARCH." >&2
            else
                echo "  No BUILD_EXCLUSIVE gates are declared in $conf; see the dkms output above." >&2
            fi
            # Check for compressed module output (not supported)
            comp="$(find "$DKMS_TREE/$PKG_NAME/$PKG_VER/$KVER" \
                    \( -name '*.ko.gz' -o -name '*.ko.xz' -o -name '*.ko.zst' \) \
                    2>/dev/null | head -1 || true)"
            [[ -z "$comp" ]] || \
                echo "  Note: found compressed module output ($comp); compressed dkms output is not supported." >&2
        fi
        log_error "Refusing to ship linux-image-$KVER-qcom without $PKG_NAME."
        exit 1
    fi

    # ── Install, extract debug, and strip each produced .ko ──────────────────
    # Mirror the in-tree module treatment:
    #   Stage 1 — install the .ko (unstripped at this point)
    #   Stage 2 — objcopy --only-keep-debug → debug package (non-destructive read)
    #   Stage 3 — strip --strip-debug on the shipped copy
    #             (--strip-debug, not full strip: kernel modules need their symtab
    #             and relocations to be loadable by the module loader)
    # Stage 2 must precede Stage 3 (debug extraction before stripping).
    #
    # Use process substitution (< <(…)) instead of a pipe to avoid running the
    # loop body in a subshell, which would prevent `exit 1` from terminating
    # the script on collision errors.
    while IFS= read -r ko; do
        b="$(basename "$ko")"
        dest="$IMAGE_PKG_DIR/lib/modules/$KVER/extra/$b"
        dbg="$DBG_PKG_DIR/usr/lib/debug/lib/modules/$KVER/extra/$b"

        # Guard: duplicate bundled module name (two manifest entries → same basename)
        if [[ -e "$dest" ]]; then
            log_error "Duplicate bundled module name: $b"
            log_error "Already bundled by an earlier manifest entry — check $MODULES_MANIFEST"
            exit 1
        fi

        # Guard: in-tree collision (bundled module shares name with an in-tree module)
        intree="$(find "$IMAGE_PKG_DIR/lib/modules/$KVER/kernel" \
                  -name "$b" -print -quit 2>/dev/null || true)"
        if [[ -n "$intree" ]]; then
            log_error "Bundled module $b collides with in-tree module: $intree"
            log_error "Module precedence on the target would be ambiguous (depmod search order)."
            exit 1
        fi

        # Stage 1: install the .ko (still unstripped at this point)
        install -D -m 644 "$ko" "$dest"

        # Stage 2: extract debug symbols before stripping (non-destructive read)
        mkdir -p "${dbg%/*}"
        "$OBJCOPY" --only-keep-debug "$dest" "$dbg" 2>/dev/null \
            || cp -a "$dest" "$dbg"

        # Stage 3: strip the shipped copy in place
        strip --strip-debug "$dest"

        log_info "  Installed: $dest (stripped)"
        log_info "  Debug:     $dbg"

    done < <(printf '%s\n' "$kos")

    log_info "Bundled $PKG_NAME modules into $(basename "$IMAGE_PKG_DIR")"
    echo

done

log_step "DKMS module bundling complete."
