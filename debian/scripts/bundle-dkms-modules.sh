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
#   4. Prints the dkms make.log for every module, built or not: the private
#      dkms tree is deleted on exit, so this is the only record left in CI.
#   5. Judges the outcome by artifact presence, not dkms exit code.
#      On failure: adds BUILD_EXCLUSIVE gate analysis when dkms attempted no
#      build, then hard-fails — a manifest entry is a presence contract.
#   6. For each produced .ko:
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
#     --headers-dir "$(CURDIR)/debian/linux-headers-$BASE/usr/src/linux-headers-$BASE" \
#     --image-pkg-dir "$(CURDIR)/debian/linux-image-$BASE" \
#     --dbg-pkg-dir   "$(CURDIR)/debian/linux-image-$BASE-dbg" \
#     --arch          "$(DKMS_ARCH)" \
#     --objcopy       "$(OBJCOPY)" \
#     --modules-manifest "$(CURDIR)/debian/dkms-modules"
#
# USAGE (standalone developer path — after manual staging):
#   debian/scripts/bundle-dkms-modules.sh \
#     --kver        6.12.0-qcom-next-20260210 \
#     --headers-dir /path/to/kernel-source/debian/linux-headers-6.12.0-qcom-next-20260210/usr/src/linux-headers-6.12.0-qcom-next-20260210 \
#     --image-pkg-dir /path/to/kernel-source/debian/linux-image-6.12.0-qcom-next-20260210 \
#     --dbg-pkg-dir   /path/to/kernel-source/debian/linux-image-6.12.0-qcom-next-20260210-dbg

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
                              \$(CURDIR)/debian/linux-headers-\$BASE/usr/src/linux-headers-\$BASE
  --image-pkg-dir DIR       Path to the linux-image staging tree root.
                            .ko files are installed under:
                              <image-pkg-dir>/lib/modules/<kver>/extra/
                            In debian/rules this is:
                              \$(CURDIR)/debian/linux-image-\$BASE
  --dbg-pkg-dir DIR         Path to the debug package staging tree root.
                            Debug symbols are installed under:
                              <dbg-pkg-dir>/usr/lib/debug/lib/modules/<kver>/extra/
                            In debian/rules this is:
                              \$(CURDIR)/debian/linux-image-\$BASE-dbg

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
     Module source is resolved via 'dpkg -L <name>-dkms', so a Debian-family
     host with a populated dpkg database is required.
  2. --headers-dir must point to a fully staged kernel headers tree.
  3. --image-pkg-dir must contain lib/modules/<kver>/kernel/ (in-tree modules)
     and boot/config-<kver> (kernel .config).
  4. --dbg-pkg-dir must exist (can be empty; subdirs are created as needed).
  5. --headers-dir must be an absolute path.
  6. This script does NOT cross-compile: dkms builds each module with the host
     toolchain (no ARCH/CROSS_COMPILE is plumbed). Run it on a native arm64
     host (or an arm64 chroot / qemu-user environment) so the produced .ko
     matches the target kernel. --arch only sets the dkms architecture label
     used for BUILD_EXCLUSIVE_ARCH gate matching, not the compiler.

MANIFEST FORMAT (debian/dkms-modules):
  One module name per line (without the -dkms suffix).
  Lines starting with # and blank lines are ignored.
  A corresponding Build-Depends entry must exist in debian/control.in.

EXAMPLES:
  # CI path (called from debian/rules):
  debian/scripts/bundle-dkms-modules.sh \\
    --kver 6.12.0-qcom-next-20260210 \\
    --headers-dir /build/kernel/debian/linux-headers-6.12.0-qcom-next-20260210/usr/src/linux-headers-6.12.0-qcom-next-20260210 \\
    --image-pkg-dir /build/kernel/debian/linux-image-6.12.0-qcom-next-20260210 \\
    --dbg-pkg-dir   /build/kernel/debian/linux-image-6.12.0-qcom-next-20260210-dbg

  # Developer standalone path:
  debian/scripts/bundle-dkms-modules.sh \\
    --kver 6.12.0-qcom-next-20260210 \\
    --headers-dir /path/to/staged/linux-headers-6.12.0-qcom-next-20260210 \\
    --image-pkg-dir /path/to/staged/linux-image-6.12.0-qcom-next-20260210 \\
    --dbg-pkg-dir   /path/to/staged/linux-image-6.12.0-qcom-next-20260210-dbg \\
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
# require_val "$@" fails cleanly when a value-taking flag is the last argument,
# instead of tripping `set -u` with a raw "$2: unbound variable".
require_val() { [[ $# -ge 2 ]] || { log_error "$1 requires a value"; exit 1; }; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --kver)              require_val "$@"; KVER="$2";              shift 2 ;;
        --headers-dir)       require_val "$@"; HEADERS_DIR="$2";       shift 2 ;;
        --image-pkg-dir)     require_val "$@"; IMAGE_PKG_DIR="$2";     shift 2 ;;
        --dbg-pkg-dir)       require_val "$@"; DBG_PKG_DIR="$2";       shift 2 ;;
        --modules-manifest)  require_val "$@"; MODULES_MANIFEST="$2";  shift 2 ;;
        --arch)              require_val "$@"; DKMS_ARCH="$2";         shift 2 ;;
        --objcopy)           require_val "$@"; OBJCOPY="$2";           shift 2 ;;
        -h|--help)           usage ;;
        # Unknown option: report on stderr and fail. Do not fall into usage(),
        # which exits 0 and would mask the misuse as success.
        *) log_error "Unknown option: $1"; log_error "Run with --help for usage."; exit 1 ;;
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
# Report any dkms configuration present on the build host.
#
# dkms hardcodes the paths it reads configuration from: /etc/dkms/framework.conf
# and /etc/dkms/framework.conf.d/*.conf in read_framework_conf, and the
# /etc/dkms/<module>*.conf overrides in read_conf. None of them can be
# redirected by an option or an environment variable, so a build cannot opt out
# of whatever the host happens to ship; it can only be explicit about it.
#
# Most of the exposure is already closed: framework.conf accepts a fixed
# variable list, it is sourced before the command line is parsed so --dkmstree
# and --kernelsourcedir are higher priority and the --directive passed to dkms
# build is applied after every conf file. What remains is tmp_location,
# parallel_jobs, the compress_*_opts, and post_transaction, the last being an
# arbitrary command dkms will run.
#
# Print whatever is there so a surprising host setting shows up in the build
# log rather than acting silently. This is deliberately not fatal: a build host
# is allowed to have dkms configured.
# ---------------------------------------------------------------------------
_dkms_host_conf=0
for _conf in /etc/dkms/framework.conf /etc/dkms/framework.conf.d/*.conf; do
    [[ -e "$_conf" ]] || continue
    _dkms_host_conf=1
    log_warn "Host dkms configuration in effect: $_conf"
    grep -vE '^[[:space:]]*(#|$)' "$_conf" | sed 's/^/  | /' || true
done
if [[ "$_dkms_host_conf" -eq 0 ]]; then
    log_info "No host dkms framework configuration found."
fi
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

    # ── Report per-module dkms.conf overrides on the build host ──────────────
    # read_conf sources these after the vendor dkms.conf, so they can change how
    # this module is built. The --directive below still wins over them, but
    # anything they set that we do not pin takes effect silently otherwise.
    for _conf in "/etc/dkms/$PKG_NAME.conf" \
                 "/etc/dkms/$PKG_NAME-$PKG_VER.conf" \
                 "/etc/dkms/$PKG_NAME-$PKG_VER-$KVER.conf" \
                 "/etc/dkms/$PKG_NAME--$KVER.conf"; do
        [[ -e "$_conf" ]] || continue
        log_warn "Host override for $PKG_NAME in effect: $_conf"
        grep -vE '^[[:space:]]*(#|$)' "$_conf" | sed 's/^/  | /' || true
    done

    # ── Run dkms build ────────────────────────────────────────────────────────
    # Capture exit code separately: dkms exit-code conventions vary across
    # versions (a BUILD_EXCLUSIVE skip can exit 0). Outcome is judged by
    # artifact presence, not exit code.
    #
    # --directive STRIP=no stops dkms from stripping the module.
    dkms_rc=0
    dkms build "$PKG_NAME/$PKG_VER" \
        --kernelsourcedir "$HEADERS_DIR" \
        --dkmstree        "$DKMS_TREE" \
        -k                "$KVER" \
        --arch            "$DKMS_ARCH" \
        --directive       "STRIP=no" \
        || dkms_rc=$?

    # ── Report the build log ──────────────────────────────────────────────────
    # dkms writes make.log inside the private dkms tree, which is deleted on
    # EXIT, so this is the only surviving record of the build in CI.
    #
    # Print it whether or not the build succeeded. A module that builds can
    # still be compiled with the wrong flags, and the compiler command lines
    # are the only place that is visible — debian/rules exports KBUILD_VERBOSE,
    # so they are all here.
    mklog="$(find "$DKMS_TREE/$PKG_NAME/$PKG_VER" -name make.log 2>/dev/null \
             | head -1 || true)"
    if [[ -n "$mklog" ]]; then
        log_step "dkms build log for $PKG_NAME/$PKG_VER ($mklog):"
        sed 's/^/  | /' "$mklog"
        echo
    fi

    # ── Judge outcome by artifacts ────────────────────────────────────────────
    # A .ko under <tree>/<name>/<ver>/<kver>/ means success.
    # dkms's make.log separates the two failure modes:
    #   - make.log present  → build was attempted and failed
    #   - no make.log       → dkms attempted no build (BUILD_EXCLUSIVE gate)
    kos="$(find "$DKMS_TREE/$PKG_NAME/$PKG_VER/$KVER" -name '*.ko' 2>/dev/null || true)"

    if [[ "$dkms_rc" -ne 0 || -z "$kos" ]]; then
        if [[ -n "$mklog" ]]; then
            log_error "dkms build failed for $PKG_NAME/$PKG_VER on kernel $KVER (dkms exit $dkms_rc); see the build log above."
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
        log_error "Refusing to ship linux-image-$KVER without $PKG_NAME."
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
        # Falling back to a full copy keeps the -dbg package usable when objcopy
        # cannot extract, but that is a degradation, not a normal outcome:
        # report what objcopy said instead of discarding it.
        mkdir -p "${dbg%/*}"
        if ! objcopy_err="$("$OBJCOPY" --only-keep-debug "$dest" "$dbg" 2>&1)"; then
            log_warn "objcopy --only-keep-debug failed for $b; copying the module instead"
            printf '%s\n' "$objcopy_err" | sed 's/^/  | /' >&2
            cp -a "$dest" "$dbg"
        fi

        # Stage 2b: the extraction above succeeds even when there is nothing to
        # extract, so assert the result actually carries DWARF.
        #
        # Capture readelf's output rather than piping it into `grep -q`: grep -q
        # exits at the first match, readelf dies of SIGPIPE on its next write,
        # and under `set -o pipefail` the pipeline reports that failure — firing
        # this assertion on a file that does carry DWARF. Whether readelf gets
        # far enough to be killed depends on stdio flush timing, so the pipeline
        # form fails only sometimes, which is worse than failing always.
        if ! dbg_sections="$(readelf -SW "$dbg" 2>&1)"; then
            log_error "readelf failed on the extracted debug file for $b"
            log_error "  debug:  $dbg"
            printf '%s\n' "$dbg_sections" | sed 's/^/  | /' >&2
            exit 1
        fi
        if ! grep -q '\.debug_info' <<< "$dbg_sections"; then
            log_error "No DWARF in the extracted debug file for $b"
            log_error "  module: $ko"
            log_error "  debug:  $dbg"
            log_error "The -dbg package would ship a debug file with no symbols."
            log_error "Check that the module was compiled with debug information"
            log_error "and that nothing stripped it before this script ran."
            log_error "Sections in the extracted debug file:"
            printf '%s\n' "$dbg_sections" | sed 's/^/  | /' >&2
            exit 1
        fi

        # Stage 3: strip the shipped copy in place
        strip --strip-debug "$dest"

        log_info "  Installed: $dest (stripped)"
        log_info "  Debug:     $dbg"

    done < <(printf '%s\n' "$kos")

    log_info "Bundled $PKG_NAME modules into $(basename "$IMAGE_PKG_DIR")"
    echo

done

log_step "DKMS module bundling complete."
