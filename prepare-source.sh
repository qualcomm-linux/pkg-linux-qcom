#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
set -e

# Prepare kernel source for Debian packaging.
#
# Responsibilities:
#   1. Inject the debian/ packaging tree into the kernel source directory.
#   2. Activate optional config fragments from debian/config-available/.
#   3. Run 'debian/rules prepare' to generate debian/control and
#      debian/changelog from *.in templates (substituting @KVER@ and @DISTRO@).
#
# This script is the CI entry point for source preparation. It is designed
# to run as a dedicated workflow step between kernel source setup
# (clone + PR application) and the build step (build-kernel.sh --skip-prepare).
#
# Separating prepare from build enables:
#   - Debusine integration: a prepared source tree can be submitted to
#     Debusine for distributed building without running the full build locally.
#   - Source package generation: a subsequent commit will add --source-pkg
#     support to run dpkg-buildpackage -S, producing a .dsc + orig tarball
#     consumable by Debusine.
#   - Observability: prepare failures surface as a distinct CI step rather
#     than being buried inside the build step.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_DISTRO="trixie"
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
optional config fragments, and runs 'debian/rules prepare' to generate
debian/control and debian/changelog from *.in templates.

This script is intended to run before build-kernel.sh (with --skip-prepare)
in CI pipelines. A subsequent commit will add --source-pkg support for
generating a source package consumable by Debusine.

OPTIONS:
  Required:
    -s, --source-dir DIR    Kernel source directory (must exist and contain
                            a kernel Makefile)

  Version control:
    -d, --distro DISTRO     Target distro: noble|questing|resolute|trixie|sid
                            (default: $DEFAULT_DISTRO)
    --localversion SUFFIX   LOCALVERSION suffix appended to the base kernel
                            version (e.g. qcom-next-20260312).
                            Auto-detected from git tag if not specified.
    --kver-extra SUFFIX     Extra suffix appended to the final KVER
                            (e.g. -ci42). Useful for CI build IDs.

  Config fragments:
    --enable-configs LIST   Comma-separated config fragments from
                            debian/config-available/ to activate for this build.
                            Fragments are copied into debian/config/ before
                            prepare runs.

  Paths:
    --debian-dir DIR        Path to the debian/ packaging directory.
                            (default: $DEBIAN_DIR)

  Debug:
    --debug                 Enable debug build: copies arch/arm64/configs/debug.config
                            from the kernel source into debian/config/ so it is
                            applied as a config fragment during the build.
                            No-op if debug.config is not present in the kernel tree.

  Misc:
    -h, --help              Show this help

EXAMPLES:
    # Minimal: auto-detect LOCALVERSION from git tag
    $0 --source-dir /path/to/kernel

    # Explicit LOCALVERSION
    $0 --source-dir /path/to/kernel --localversion qcom-next-20260312

    # With CI build ID suffix
    $0 --source-dir /path/to/kernel --localversion qcom-next-20260312 --kver-extra -ci42

    # With optional config fragments
    $0 --source-dir /path/to/kernel --enable-configs docker,systemd-boot

    # Target Ubuntu Noble
    $0 --source-dir /path/to/kernel --distro noble --localversion qcom-next-20260312
EOF
    exit 0
}

# Defaults
SOURCE_DIR=""; DISTRO="$DEFAULT_DISTRO"
LOCALVERSION=""; KVER_EXTRA=""; ENABLE_CONFIGS=""; DEBUG=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--source-dir)    SOURCE_DIR="$2";    shift 2 ;;
        -d|--distro)        DISTRO="$2";        shift 2 ;;
        --localversion)     LOCALVERSION="$2";  shift 2 ;;
        --kver-extra)       KVER_EXTRA="$2";    shift 2 ;;
        --enable-configs)   ENABLE_CONFIGS="$2"; shift 2 ;;
        --debian-dir)       DEBIAN_DIR="$2";    shift 2 ;;
        --debug)            DEBUG=true;         shift   ;;
        -h|--help)          usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# ── Validate inputs ───────────────────────────────────────────────────────────
[[ -n "$SOURCE_DIR" ]] || { log_error "--source-dir is required"; usage; }
[[ -d "$SOURCE_DIR" ]] || { log_error "Source directory not found: $SOURCE_DIR"; exit 1; }
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"

VALID_DISTROS=(noble questing resolute trixie sid)
[[ " ${VALID_DISTROS[*]} " =~ " $DISTRO " ]] || {
    log_error "Invalid distro: $DISTRO (valid: ${VALID_DISTROS[*]})"
    exit 1
}

[[ -d "$DEBIAN_DIR" ]] || { log_error "Debian dir not found: $DEBIAN_DIR"; exit 1; }

# ── Helper: derive LOCALVERSION from a tag name ──────────────────────────────
# qcom-next-6.19-rc8-20260210 → qcom-next-20260210
_auto_localversion() {
    local tag="$1"
    if [[ "$tag" =~ ^([a-z-]+)-[0-9]+\.[0-9]+.*-([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
    else
        echo "$tag"
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
        log_warn "Package will be named linux-image-<base-kver>-qcom (no branch/ABI suffix)."
        log_warn "Use --localversion to specify, e.g.: --localversion qcom-next-20260312"
    fi
fi

log_step "Configuration:"
log_info "  Source dir:    $SOURCE_DIR"
log_info "  Distro:        $DISTRO"
[[ -n "$LOCALVERSION" ]]   && log_info "  LOCALVERSION:  $LOCALVERSION"
[[ -n "$KVER_EXTRA" ]]     && log_info "  KVER_EXTRA:    $KVER_EXTRA"
[[ -n "$ENABLE_CONFIGS" ]] && log_info "  Extra configs: $ENABLE_CONFIGS"
[[ "$DEBUG" == true ]]     && log_info "  Debug build:   yes"
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
log_info "Copied $ACTUAL_DEBIAN_DIR → $SOURCE_DIR/debian"

# ── Debug config fragment ─────────────────────────────────────────────────────
# When --debug is set, copy arch/arm64/configs/debug.config from the kernel
# source into debian/config/ so it is applied as a standard config fragment
# in override_dh_auto_configure Step 3 alongside squashfs.config.
# This avoids any dependency on DEB_BUILD_PROFILES being passed through the
# container boundary and works identically for CI, local developer, and Debusine.
if [[ "$DEBUG" == true ]]; then
    DEBUG_CONFIG="$SOURCE_DIR/arch/arm64/configs/debug.config"
    if [[ -f "$DEBUG_CONFIG" ]]; then
        cp "$DEBUG_CONFIG" "$SOURCE_DIR/debian/config/debug.config"
        log_info "Copied arch/arm64/configs/debug.config into debian/config/"
    else
        log_warn "arch/arm64/configs/debug.config not found in kernel source — debug config will not be applied"
    fi
fi

# ── Optional config fragments ────────────────────────────────────────────────
if [[ -n "$ENABLE_CONFIGS" ]]; then
    log_step "Activating config fragments: $ENABLE_CONFIGS"
    AVAIL_DIR="$SOURCE_DIR/debian/config-available"
    ACTIVE_DIR="$SOURCE_DIR/debian/config"
    mkdir -p "$ACTIVE_DIR"
    IFS=',' read -ra CFG_LIST <<< "$ENABLE_CONFIGS"
    for cfg in "${CFG_LIST[@]}"; do
        cfg="${cfg// /}"
        frag="${cfg%.config}.config"
        [[ -f "$AVAIL_DIR/$frag" ]] || {
            log_error "Fragment not found: $frag"
            log_error "Available: $(ls "$AVAIL_DIR"/*.config 2>/dev/null | xargs -n1 basename | sed 's/\.config//' | tr '\n' ' ')"
            exit 1
        }
        cp "$AVAIL_DIR/$frag" "$ACTIVE_DIR/$frag"
        log_info "  Enabled: $frag"
    done
fi

# ── Prepare: generate debian/control + debian/changelog ─────────────────────
log_step "Running debian/rules prepare..."
PREPARE_ARGS="DISTRO=$DISTRO"
[[ -n "$LOCALVERSION" ]] && PREPARE_ARGS="$PREPARE_ARGS LOCALVERSION=-$LOCALVERSION"
[[ -n "$KVER_EXTRA" ]]   && PREPARE_ARGS="$PREPARE_ARGS KVER_EXTRA=$KVER_EXTRA"
# shellcheck disable=SC2086
make -f "$SOURCE_DIR/debian/rules" -C "$SOURCE_DIR" prepare $PREPARE_ARGS

echo
log_step "Source preparation complete."
log_info "Generated: $SOURCE_DIR/debian/control"
log_info "Generated: $SOURCE_DIR/debian/changelog"
