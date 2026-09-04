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
#      debian/localversion, debian/pkgversion, and debian/dkms-modules from the
#      *.in templates and the --dkms list.
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
debian/localversion, debian/pkgversion, and debian/dkms-modules from the
*.in templates and the --dkms list.

OPTIONS:
  Required:
    -s, --source-dir DIR      Kernel source directory (must exist and contain
                              a kernel Makefile)

  Version control:
    -d, --distro DISTRO       Target suite: trixie|forky|sid|noble|questing|resolute
                              (default: $DEFAULT_DISTRO)
    --localversion SUFFIX     LOCALVERSION suffix appended to the base kernel
                              version (e.g. +qcom-next-20260722).
                              Auto-detected from git tag if not specified.
    --snapshot SNAPSHOT       Dated component of the Debian version: YYYYMMDD
                              with an optional .<respin> ordinal (e.g.
                              20260722 or 20260722.1). Auto-detected from git
                              tag alongside --localversion; pass it explicitly
                              whenever --localversion is passed explicitly.
    --git-sha SHA             Full commit SHA the build was cut from. Its
                              first 12 characters discriminate two builds of
                              one snapshot (a moved tag) in the version
                              strings; the full value is recorded in the
                              changelog. Auto-detected from HEAD.
    --kver-extra SUFFIX       Extra suffix appended to the final KVER
                              (e.g. -ci42).
    --git-clone URL           Kernel repository URL, recorded in the changelog.
    --git-ref REF             Resolved kernel ref (tag or branch), recorded in
                              the changelog.

  Package naming:
    --srcpkg NAME             Source package name (default: $DEFAULT_SRCPKG)
    --binpkg NAME             Binary metapackage name (default: $DEFAULT_BINPKG)
    --debian-revision REV     Debian revision component of the package version
                              (default: $DEFAULT_DEBIAN_REVISION)

  Config fragments:
    --kernel-config LIST      Comma-separated fragments to apply in addition to
                              debian/config-available/, every entry of which is
                              applied to every build regardless of this option.
                              An "intree:" prefix names a path relative to the
                              kernel source root, for fragments that ship with
                              the kernel and are versioned with it
                              (e.g. intree:arch/arm64/configs/qcom_debug.config
                              or intree:kernel/configs/debug.config). The path
                              must end in .config; absolute paths and ".." are
                              rejected.
                              A bare name is accepted for compatibility but is
                              redundant, since that fragment is already applied.
                              Entries are processed in LC_ALL=C sorted order.

  DKMS modules:
    --dkms LIST               Comma-separated out-of-tree DKMS modules to build
                              against this kernel and bundle into
                              linux-image-<KVER>, each named without the -dkms
                              suffix (e.g. --dkms kgsl,camx). Each entry needs a
                              <name>-dkms package available to the build; the
                              Build-Depends entry is generated from this list.
                              Empty (the default) bundles no modules.

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
       --localversion +qcom-next-20260722 \\
       --srcpkg linux-qcom-next \\
       --binpkg linux-image-qcom-next \\
       --debian-revision 0qcom1 \\
       --kernel-config squashfs,systemd-boot,qcom-imsdk,docker,qemu-boot,usb-can \\
       --dkms kgsl
EOF
    exit 1
}

# Defaults
SOURCE_DIR=""
DISTRO="$DEFAULT_DISTRO"
LOCALVERSION=""
SNAPSHOT=""
KVER_EXTRA=""
SRCPKG="$DEFAULT_SRCPKG"
BINPKG="$DEFAULT_BINPKG"
DEBIAN_REVISION="$DEFAULT_DEBIAN_REVISION"
KERNEL_CONFIG=""
DKMS_MODULES=""
GIT_CLONE=""
GIT_REF=""
GIT_SHA=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--source-dir)      SOURCE_DIR="$2";       shift 2 ;;
        -d|--distro)          DISTRO="$2";            shift 2 ;;
        --localversion)       LOCALVERSION="$2";      shift 2 ;;
        --snapshot)           SNAPSHOT="$2";          shift 2 ;;
        --git-sha)            GIT_SHA="$2";           shift 2 ;;
        --kver-extra)         KVER_EXTRA="$2";        shift 2 ;;
        --git-clone)          GIT_CLONE="$2";         shift 2 ;;
        --git-ref)            GIT_REF="$2";           shift 2 ;;
        --srcpkg)             SRCPKG="$2";            shift 2 ;;
        --binpkg)             BINPKG="$2";            shift 2 ;;
        --debian-revision)    DEBIAN_REVISION="$2";   shift 2 ;;
        --kernel-config)      KERNEL_CONFIG="$2";     shift 2 ;;
        --dkms)               DKMS_MODULES="$2";      shift 2 ;;
        --debian-dir)         DEBIAN_DIR="$2";        shift 2 ;;
        -h|--help)            usage ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
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

# ── Resolve the commit, once ─────────────────────────────────────────────────
# One SHA, used at two widths: the first 12 characters go in the version strings
# (short enough to keep a boot menu readable), the full value goes in the
# changelog. Deriving one from the other is what keeps them the same commit.
[[ -n "$GIT_SHA" ]] || GIT_SHA=$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || true)
GITSHA="${GIT_SHA:0:12}"

# ── Helper: derive LOCALVERSION, SNAPSHOT and GITSHA from a tag name ─────────
# qcom-next-7.2-rc3-20260722   -> +qcom-next-20260722-g<sha>   / 20260722
# qcom-next-7.2-rc3-20260722.1 -> +qcom-next-20260722.1-g<sha> / 20260722.1
#
# The trailing component is a YYYYMMDD snapshot with an optional respin ordinal
# for a second tag cut on the same day. Matching the date width explicitly (and
# not just "trailing digits") keeps the ordinal attached to it.
#
# All three fields come out of the tag and HEAD together. Recovering them from
# LOCALVERSION afterwards would mean parsing a string that also holds a variant
# name and a hex SHA that can end in eight digits.
_auto_version_fields() {
    local tag="$1"
    if [[ "$tag" =~ ^([a-z-]+)-[0-9]+\.[0-9]+.*-([0-9]{8}(\.[0-9]+)?)$ ]]; then
        SNAPSHOT="${BASH_REMATCH[2]}"
        LOCALVERSION="+${BASH_REMATCH[1]}-${SNAPSHOT}-g${GITSHA}"
    else
        LOCALVERSION="+$tag"
        SNAPSHOT=""
    fi
}

# ── Auto-detect LOCALVERSION, SNAPSHOT and GITSHA from git (if not provided) ──
if [[ -z "$LOCALVERSION" ]]; then
    GIT_TAG=$(git -C "$SOURCE_DIR" describe --tags --exact-match 2>/dev/null || true)
    if [[ -n "$GIT_TAG" ]]; then
        _auto_version_fields "$GIT_TAG"
        log_info "Auto-detected LOCALVERSION='$LOCALVERSION' SNAPSHOT='$SNAPSHOT' GITSHA='$GITSHA' from tag '$GIT_TAG'"
    else
        log_warn "LOCALVERSION not set and no exact git tag found."
        log_warn "Package will be named linux-image-<base-kver> (no branch/date suffix)."
        log_warn "Use --localversion to specify, e.g.: --localversion +qcom-next-20260722"
    fi
elif [[ -z "$SNAPSHOT" ]]; then
    # An explicit --localversion is not parsed for a snapshot; say so rather
    # than silently dropping the dated component from the Debian version.
    log_warn "--localversion given without --snapshot: the Debian version will"
    log_warn "carry no +git<date> component. Pass --snapshot to supply one."
fi

log_step "Configuration:"
log_info "  Source dir:       $SOURCE_DIR"
log_info "  Distro:           $DISTRO"
log_info "  Source package:   $SRCPKG"
log_info "  Binary metapkg:   $BINPKG"
log_info "  Debian revision:  $DEBIAN_REVISION"
[[ -n "$LOCALVERSION" ]]   && log_info "  LOCALVERSION:     $LOCALVERSION"
[[ -n "$SNAPSHOT" ]]       && log_info "  SNAPSHOT:         $SNAPSHOT"
[[ -n "$GITSHA" ]]         && log_info "  GITSHA:           $GITSHA"
[[ -n "$KVER_EXTRA" ]]     && log_info "  KVER_EXTRA:       $KVER_EXTRA"
[[ -n "$KERNEL_CONFIG" ]]  && log_info "  Kernel config:    $KERNEL_CONFIG"
[[ -n "$DKMS_MODULES" ]]   && log_info "  DKMS modules:     $DKMS_MODULES"
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
# Every fragment in debian/config-available/ is applied to every build. The
# directory is the packaging fragment set, kept in sync with kernel-configs/ in
# qcom-deb-images; there is no per-variant subset to opt into.
#
# --kernel-config carries anything beyond that set, which today means "intree:"
# fragments shipped by the kernel source. Bare names are still accepted so that
# existing callers keep working, but they are redundant: the fragment they name
# has already been applied.
ACTIVE_DIR="$SOURCE_DIR/debian/config"
AVAIL_DIR="$SOURCE_DIR/debian/config-available"
mkdir -p "$ACTIVE_DIR"

log_step "Applying all packaging fragments from debian/config-available/"
if compgen -G "$AVAIL_DIR/*.config" > /dev/null; then
    # LC_ALL=C so the order does not depend on the builder's locale.
    while IFS= read -r src; do
        frag="$(basename "$src")"
        cp "$src" "$ACTIVE_DIR/$frag"
        log_info "  Applied: $frag (from debian/config-available)"
    done < <(printf '%s\n' "$AVAIL_DIR"/*.config | LC_ALL=C sort)
else
    log_warn "No fragments found in debian/config-available/"
fi

if [[ -n "$KERNEL_CONFIG" ]]; then
    log_step "Resolving additional fragments: $KERNEL_CONFIG"
    IFS=',' read -ra CFG_LIST <<< "$KERNEL_CONFIG"
    # Sort so processing and logs are deterministic regardless of the order the
    # caller listed them in.
    while IFS= read -r cfg; do
        [[ -n "$cfg" ]] || continue
        if [[ "$cfg" == intree:* ]]; then
            # In-tree fragment, shipped by the kernel source rather than by this
            # repository. Referenced instead of vendored so it stays versioned
            # with the kernel it targets. The entry spells the whole path
            # relative to the kernel source root, so fragments outside
            # arch/arm64/configs/ are reachable too (kernel/configs/debug.config).
            path="${cfg#intree:}"
            case "$path" in
                "" | /* | ".." | "../"* | *"/../"* | *"/..")
                    log_error "Invalid in-tree fragment: ${cfg}"
                    log_error "Expected a path relative to the kernel source root, e.g. intree:arch/arm64/configs/qcom_debug.config"
                    exit 1
                    ;;
            esac
            # debian/rules globs debian/config/*.config, so a fragment named
            # anything else would be copied in and then silently ignored.
            [[ "$path" == *.config ]] || {
                log_error "In-tree fragment must name a .config file: $cfg"
                log_error "Spell the whole path, e.g. intree:arch/arm64/configs/qcom_debug.config"
                exit 1
            }
            src="$SOURCE_DIR/$path"
            frag="$(basename "$path")"
            dir="$(dirname "$path")"
            [[ -f "$src" ]] || {
                log_error "In-tree fragment not found: $path"
                log_error "Paths are relative to the kernel source root ($SOURCE_DIR)."
                avail="$(ls "$SOURCE_DIR/$dir"/*.config 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
                [[ -n "$avail" ]] && log_error "Available in $dir/: $avail"
                exit 1
            }
            # The fragment keeps only its basename in debian/config/, so two
            # in-tree paths can collide with each other as well as with a
            # packaging fragment (kernel/configs/hardening.config and
            # arch/arm64/configs/hardening.config both exist).
            [[ -e "$ACTIVE_DIR/$frag" ]] && {
                log_error "Fragment name collision in debian/config/: $frag"
                log_error "An in-tree fragment must not share a filename with an already applied fragment."
                exit 1
            }
            cp "$src" "$ACTIVE_DIR/$frag"
            log_info "  Applied: $frag (from $dir)"
        else
            frag="${cfg%.config}.config"
            [[ -f "$AVAIL_DIR/$frag" ]] || {
                log_error "Fragment not found in config-available/: $frag"
                log_error "Available: $(ls "$AVAIL_DIR"/*.config 2>/dev/null | xargs -n1 basename | sed 's/\.config//' | tr '\n' ' ')"
                exit 1
            }
            log_info "  Already applied: $frag (all of config-available is applied)"
        fi
    done < <(printf '%s\n' "${CFG_LIST[@]}" | tr -d ' ' | LC_ALL=C sort)
fi

# ── Prepare: generate control, changelog, localversion, pkgversion ───────────
log_step "Running debian/rules prepare..."
PREPARE_ARGS="DISTRO=$DISTRO SRCPKG=$SRCPKG BINPKG=$BINPKG DEBIAN_REVISION=$DEBIAN_REVISION"
[[ -n "$LOCALVERSION" ]] && PREPARE_ARGS="$PREPARE_ARGS LOCALVERSION=$LOCALVERSION"
[[ -n "$SNAPSHOT" ]]     && PREPARE_ARGS="$PREPARE_ARGS SNAPSHOT=$SNAPSHOT"
[[ -n "$GITSHA" ]]       && PREPARE_ARGS="$PREPARE_ARGS GITSHA=$GITSHA"
[[ -n "$KVER_EXTRA" ]]   && PREPARE_ARGS="$PREPARE_ARGS KVER_EXTRA=$KVER_EXTRA"
# Source provenance for debian/changelog. LOCALVERSION identifies a build by
# date, not by commit, so the SHA recorded here is what makes a build traceable
# back to exact source -- particularly for branch-tip builds.
[[ -n "$GIT_CLONE" ]]    && PREPARE_ARGS="$PREPARE_ARGS GIT_CLONE=$GIT_CLONE"
[[ -n "$GIT_REF" ]]      && PREPARE_ARGS="$PREPARE_ARGS GIT_REF=$GIT_REF"
[[ -n "$GIT_SHA" ]]      && PREPARE_ARGS="$PREPARE_ARGS GIT_SHA=$GIT_SHA"
# Spaces are stripped so a list written as "kgsl, camx" stays a single make
# argument; debian/rules validates the names it is given.
[[ -n "$DKMS_MODULES" ]] && PREPARE_ARGS="$PREPARE_ARGS DKMS_MODULES=$(tr -d ' ' <<< "$DKMS_MODULES")"
# shellcheck disable=SC2086
make -f "$SOURCE_DIR/debian/rules" -C "$SOURCE_DIR" prepare $PREPARE_ARGS

echo
log_step "Source preparation complete."
log_info "Generated: $SOURCE_DIR/debian/control"
log_info "Generated: $SOURCE_DIR/debian/changelog"
log_info "Generated: $SOURCE_DIR/debian/localversion"
log_info "Generated: $SOURCE_DIR/debian/pkgversion"
log_info "Generated: $SOURCE_DIR/debian/dkms-modules"
