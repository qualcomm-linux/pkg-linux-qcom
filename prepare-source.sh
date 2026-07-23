#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
set -e

# Prepare kernel source for Debian packaging.
#
# Responsibilities:
#   1. Inject the debian/ packaging tree into the kernel source directory.
#   2. Activate optional config fragments from debian/config-available/ into
#      debian/config/ based on the --kernel-config list.
#   3. Run 'debian/rules prepare' to generate debian/control, debian/changelog,
#      debian/localversion, and debian/pkgversion from *.in templates.
#
# This script is the CI entry point for source preparation. It runs as a
# dedicated workflow step between kernel source setup (clone + PR application)
# and the build step (build-kernel.sh --skip-prepare or Debusine submission).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_DISTRO="trixie"
DEFAULT_SRCPKG="linux-qcom-next"
DEFAULT_BINPKG="linux-image-qcom-next"
DEFAULT_DEBIAN_REVISION="0qcom1"
DEBIAN_DIR="$SCRIPT_DIR/debian"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Prepare kernel source for Debian packaging.

Injects debian/ packaging metadata into the kernel source tree, activates
optional config fragments from debian/config-available/, and runs
'debian/rules prepare' to generate debian/control, debian/changelog,
debian/localversion, and debian/pkgversion from *.in templates.

OPTIONS:
  Required:
    -s, --source-dir DIR      Kernel source directory (must exist and contain
                              a kernel Makefile)

  Version control:
    -d, --distro DISTRO       Target suite: trixie|forky|sid|noble|questing|resolute
                              (default: $DEFAULT_DISTRO)
    --localversion SUFFIX     LOCALVERSION suffix appended to the base kernel
                              version (e.g. -qcom-next-20260722).
                              Auto-detected from git tag if not specified.
    --kver-extra SUFFIX       Extra suffix appended to the final KVER
                              (e.g. -ci42).

  Package naming:
    --srcpkg NAME             Source package name (default: $DEFAULT_SRCPKG)
    --binpkg NAME             Binary metapackage name (default: $DEFAULT_BINPKG)
    --debian-revision REV     Debian revision component of the package version
                              (default: $DEFAULT_DEBIAN_REVISION)

  Config fragments:
    --kernel-config LIST      Comma-separated fragment names from
                              debian/config-available/ to activate for this
                              build (e.g. squashfs,docker,systemd-boot).
                              Fragments are copied into debian/config/ before
                              prepare runs. If not specified, no packaging
                              fragments are activated (only kernel-source
                              fragments qcom.config and prune.config apply).

  Debug:
    --debug                   Enable debug build: copies arch/arm64/configs/debug.config
                              from the kernel source into debian/config/ so it is
                              applied as a config fragment during the build.

  Paths:
    --debian-dir DIR          Path to the debian/ packaging directory
                              (default: $DEBIAN_DIR)

  Misc:
    -h, --help                Show this help

EXAMPLES:
    # Minimal: auto-detect LOCALVERSION from git tag, default package names
    $0 --source-dir /path/to/kernel

    # Full CI invocation with all options
    $0 --source-dir /path/to/kernel \\
       --distro trixie \\
       --localversion -qcom-next-20260722 \\
       --srcpkg linux-qcom-next \\
       --binpkg linux-image-qcom-next \\
       --debian-revision 0qcom1 \\
       --kernel-config squashfs,systemd-boot,qcom-imsdk,docker,qemu-boot,usb-can
EOF
    exit 0
}

# Defaults
SOURCE_DIR=""
DISTRO="$DEFAULT_DISTRO"
LOCALVERSION=""
KVER_EXTRA=""
SRCPKG="$DEFAULT_SRCPKG"
BINPKG="$DEFAULT_BINPKG"
DEBIAN_REVISION="$DEFAULT_DEBIAN_REVISION"
KERNEL_CONFIG=""
DEBUG=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--source-dir)      SOURCE_DIR="$2";       shift 2 ;;
        -d|--distro)          DISTRO="$2";            shift 2 ;;
        --localversion)       LOCALVERSION="$2";      shift 2 ;;
        --kver-extra)         KVER_EXTRA="$2";        shift 2 ;;
        --srcpkg)             SRCPKG="$2";            shift 2 ;;
        --binpkg)             BINPKG="$2";            shift 2 ;;
        --debian-revision)    DEBIAN_REVISION="$2";   shift 2 ;;
        --kernel-config)      KERNEL_CONFIG="$2";     shift 2 ;;
        --debian-dir)         DEBIAN_DIR="$2";        shift 2 ;;
        --debug)              DEBUG=true;             shift   ;;
        -h|--help)            usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# ── Validate inputs ───────────────────────────────────────────────────────────
[[ -n "$SOURCE_DIR" ]] || { log_error "--source-dir is required"; usage; }
[[ -d "$SOURCE_DIR" ]] || { log_error "Source directory not found: $SOURCE_DIR"; exit 1; }
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"

VALID_DISTROS=(noble questing resolute trixie forky sid unstable)
[[ " ${VALID_DISTROS[*]} " =~ " $DISTRO " ]] || {
    log_error "Invalid distro: $DISTRO (valid: ${VALID_DISTROS[*]})"
    exit 1
}

[[ -d "$DEBIAN_DIR" ]] || { log_error "Debian dir not found: $DEBIAN_DIR"; exit 1; }

# ── Helper: derive LOCALVERSION from a tag name ──────────────────────────────
# qcom-next-7.2-rc3-20260722 -> -qcom-next-20260722
_auto_localversion() {
    local tag="$1"
    if [[ "$tag" =~ ^([a-z-]+)-[0-9]+\.[0-9]+.*-([0-9]+)$ ]]; then
        echo "-${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
    else
        echo "-$tag"
    fi
}

# ── Auto-detect LOCALVERSION from git tag (if not provided) ──────────────────
if [[ -z "$LOCALVERSION" ]]; then
    GIT_TAG=$(git -C "$SOURCE_DIR" describe --tags --exact-match 2>/dev/null || true)
    if [[ -n "$GIT_TAG" ]]; then
        LOCALVERSION="$(_auto_localversion "$GIT_TAG")"
        log_info "Auto-detected LOCALVERSION='$LOCALVERSION' from tag '$GIT_TAG'"
    else
        log_warn "LOCALVERSION not set and no exact git tag found."
        log_warn "Package will be named linux-image-<base-kver> (no branch/date suffix)."
        log_warn "Use --localversion to specify, e.g.: --localversion -qcom-next-20260722"
    fi
fi

log_step "Configuration:"
log_info "  Source dir:       $SOURCE_DIR"
log_info "  Distro:           $DISTRO"
log_info "  Source package:   $SRCPKG"
log_info "  Binary metapkg:   $BINPKG"
log_info "  Debian revision:  $DEBIAN_REVISION"
[[ -n "$LOCALVERSION" ]]   && log_info "  LOCALVERSION:     $LOCALVERSION"
[[ -n "$KVER_EXTRA" ]]     && log_info "  KVER_EXTRA:       $KVER_EXTRA"
[[ -n "$KERNEL_CONFIG" ]]  && log_info "  Kernel config:    $KERNEL_CONFIG"
[[ "$DEBUG" == true ]]     && log_info "  Debug build:      yes"
echo

# ── Inject debian/ ───────────────────────────────────────────────────────────
log_step "Injecting debian/ packaging files..."
[[ -d "$SOURCE_DIR/debian" ]] && {
    log_warn "Removing existing debian/ in kernel source"
    rm -rf "$SOURCE_DIR/debian"
}

ACTUAL_DEBIAN_DIR="$DEBIAN_DIR"
[[ -d "$DEBIAN_DIR/debian" ]] && ACTUAL_DEBIAN_DIR="$DEBIAN_DIR/debian"
[[ -d "$ACTUAL_DEBIAN_DIR" ]] || { log_error "debian/ not found: $ACTUAL_DEBIAN_DIR"; exit 1; }

cp -r "$ACTUAL_DEBIAN_DIR" "$SOURCE_DIR/debian"
log_info "Copied $ACTUAL_DEBIAN_DIR -> $SOURCE_DIR/debian"

# ── Activate config fragments from config-available/ ─────────────────────────
# debian/config/ is empty by default. Fragments are activated by copying named
# files from debian/config-available/ into debian/config/ here, before
# debian/rules prepare runs. override_dh_auto_configure globs debian/config/*.config
# and applies whatever is present — no rules changes needed.
if [[ -n "$KERNEL_CONFIG" ]]; then
    log_step "Activating config fragments: $KERNEL_CONFIG"
    AVAIL_DIR="$SOURCE_DIR/debian/config-available"
    ACTIVE_DIR="$SOURCE_DIR/debian/config"
    mkdir -p "$ACTIVE_DIR"
    IFS=',' read -ra CFG_LIST <<< "$KERNEL_CONFIG"
    for cfg in "${CFG_LIST[@]}"; do
        cfg="${cfg// /}"
        frag="${cfg%.config}.config"
        [[ -f "$AVAIL_DIR/$frag" ]] || {
            log_error "Fragment not found in config-available/: $frag"
            log_error "Available: $(ls "$AVAIL_DIR"/*.config 2>/dev/null | xargs -n1 basename | sed 's/\.config//' | tr '\n' ' ')"
            exit 1
        }
        cp "$AVAIL_DIR/$frag" "$ACTIVE_DIR/$frag"
        log_info "  Activated: $frag"
    done
else
    log_info "No --kernel-config specified: debian/config/ remains empty."
    log_info "Only kernel-source fragments (qcom.config, prune.config) will be applied."
fi

# ── Debug config fragment ─────────────────────────────────────────────────────
if [[ "$DEBUG" == true ]]; then
    DEBUG_CONFIG="$SOURCE_DIR/kernel/configs/debug.config"
    if [[ -f "$DEBUG_CONFIG" ]]; then
        mkdir -p "$SOURCE_DIR/debian/config"
        cp "$DEBUG_CONFIG" "$SOURCE_DIR/debian/config/debug.config"
        log_info "Copied kernel/configs/debug.config into debian/config/"
    else
        log_warn "kernel/configs/debug.config not found — debug config will not be applied"
    fi
fi

# ── Prepare: generate control, changelog, localversion, pkgversion ───────────
log_step "Running debian/rules prepare..."
PREPARE_ARGS="DISTRO=$DISTRO SRCPKG=$SRCPKG BINPKG=$BINPKG DEBIAN_REVISION=$DEBIAN_REVISION"
[[ -n "$LOCALVERSION" ]] && PREPARE_ARGS="$PREPARE_ARGS LOCALVERSION=$LOCALVERSION"
[[ -n "$KVER_EXTRA" ]]   && PREPARE_ARGS="$PREPARE_ARGS KVER_EXTRA=$KVER_EXTRA"
# shellcheck disable=SC2086
make -f "$SOURCE_DIR/debian/rules" -C "$SOURCE_DIR" prepare $PREPARE_ARGS

echo
log_step "Source preparation complete."
log_info "Generated: $SOURCE_DIR/debian/control"
log_info "Generated: $SOURCE_DIR/debian/changelog"
log_info "Generated: $SOURCE_DIR/debian/localversion"
log_info "Generated: $SOURCE_DIR/debian/pkgversion"
