#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
set -e

# Build orchestrator for linux-image-<kver>-qcom Debian/Ubuntu kernel packages.
# Modes: docker (default), native, sbuild

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_REPO="git@github.com:qualcomm-linux/kernel.git"
DEFAULT_BRANCH="qcom-next"
DEFAULT_DISTRO="trixie"
DEFAULT_BUILD_MODE="docker"
KERNEL_DIR="$SCRIPT_DIR/kernel-source"
OUTPUT_BASE_DIR="$SCRIPT_DIR/kernel-build"
DEBIAN_DIR="$SCRIPT_DIR/debian"
DOCKER_PKG_BUILD="${DOCKER_PKG_BUILD:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Build linux-image-<kver>-qcom Debian/Ubuntu kernel packages.

OPTIONS:
  Source selection (mutually exclusive):
    --local-source DIR      Use existing local kernel source (skip clone/fetch)
    -t, --tag TAG           Checkout specific tag
    -l, --latest-tag        Select the latest qcom-next-* tag automatically
    -b, --branch BRANCH     Branch to use (default: $DEFAULT_BRANCH)
    -r, --repo URL          Kernel repository URL (default: $DEFAULT_REPO)

  Version control:
    --localversion TAG      LOCALVERSION suffix (e.g. qcom-next-20260312)
                            Auto-detected from git tag when using --local-source
    --kver-extra SUFFIX     Extra suffix appended to the derived KVER, e.g.:
                              --kver-extra -mybuild
                            Results in: 7.0.0-rc2-qcom-next-20260312-mybuild
                            Useful for CI build IDs or local user builds.

  Build control:
    -d, --distro DISTRO     Target distro: noble|questing|resolute|trixie|sid
                            (default: $DEFAULT_DISTRO)
    --build-mode MODE       docker|native|sbuild (default: $DEFAULT_BUILD_MODE)
    --docker-build PATH     Path to docker_deb_build.py (docker mode)
    --profiles PROFILES     DEB_BUILD_PROFILES (e.g. debug)
    --enable-configs LIST   Comma-separated config fragments from
                            debian/config-available/ to activate

  Paths:
    -k, --kernel-dir DIR    Kernel source directory (default: $KERNEL_DIR)
    -o, --output-dir DIR    Output directory (default: $OUTPUT_BASE_DIR/<distro>)
    --debian-dir DIR        debian/ packaging directory (default: $DEBIAN_DIR)

  Misc:
    --skip-prepare          Skip the call to prepare-source.sh. Use in CI when
                            prepare-source.sh has already been run as a
                            dedicated prior step. Implies --local-source is
                            also set.
    --clean                 Remove kernel source dir before syncing
    -h, --help              Show this help

EXAMPLES:
    $0 --latest-tag
    $0 --latest-tag --build-mode native
    $0 --tag qcom-next-6.12.0-20260210 --distro noble
    $0 --local-source /path/to/kernel --build-mode native
    $0 --local-source /path/to/kernel --kver-extra -mybuild
    $0 --latest-tag --enable-configs docker,systemd-boot
    $0 --latest-tag --profiles debug

DISTRIBUTIONS:
    noble     Ubuntu 24.04 LTS
    questing  Ubuntu 25.10
    resolute  Ubuntu 26.04
    trixie    Debian 13 (default)
    sid       Debian unstable
EOF
    exit 0
}

# Defaults
TAG=""; LATEST_TAG=false; BRANCH="$DEFAULT_BRANCH"; REPO="$DEFAULT_REPO"
DISTRO="$DEFAULT_DISTRO"; BUILD_MODE="$DEFAULT_BUILD_MODE"
LOCALVERSION=""; KVER_EXTRA=""; PROFILES=""; CLEAN=false
LOCAL_SOURCE=""; ENABLE_CONFIGS=""; SKIP_PREPARE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--tag)           TAG="$2";           shift 2 ;;
        -l|--latest-tag)    LATEST_TAG=true;    shift   ;;
        -b|--branch)        BRANCH="$2";        shift 2 ;;
        -r|--repo)          REPO="$2";          shift 2 ;;
        -k|--kernel-dir)    KERNEL_DIR="$2";    shift 2 ;;
        -o|--output-dir)    OUTPUT_DIR="$2";    shift 2 ;;
        --debian-dir)       DEBIAN_DIR="$2";    shift 2 ;;
        -d|--distro)        DISTRO="$2";        shift 2 ;;
        --local-source)     LOCAL_SOURCE="$2";  shift 2 ;;
        --docker-build)     DOCKER_PKG_BUILD="$2"; shift 2 ;;
        --localversion)     LOCALVERSION="$2";  shift 2 ;;
        --kver-extra)       KVER_EXTRA="$2";    shift 2 ;;
        --profiles)         PROFILES="$2";      shift 2 ;;
        --enable-configs)   ENABLE_CONFIGS="$2"; shift 2 ;;
        --build-mode)       BUILD_MODE="$2";    shift 2 ;;
        --skip-prepare)     SKIP_PREPARE=true;  shift   ;;
        --clean)            CLEAN=true;         shift   ;;
        -h|--help)          usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

[[ -z "${OUTPUT_DIR:-}" ]] && OUTPUT_DIR="$OUTPUT_BASE_DIR/$DISTRO"

# Validate distro and build mode
VALID_DISTROS=(noble questing resolute trixie sid)
VALID_MODES=(docker native sbuild)
[[ " ${VALID_DISTROS[*]} " =~ " $DISTRO " ]]    || { log_error "Invalid distro: $DISTRO (valid: ${VALID_DISTROS[*]})"; exit 1; }
[[ " ${VALID_MODES[*]} " =~ " $BUILD_MODE " ]]  || { log_error "Invalid build mode: $BUILD_MODE (valid: ${VALID_MODES[*]})"; exit 1; }

# Locate docker_deb_build.py (docker mode)
if [[ "$BUILD_MODE" == "docker" && -z "$DOCKER_PKG_BUILD" ]]; then
    for p in "$HOME/docker-pkg-build/docker_deb_build.py" \
              "$SCRIPT_DIR/docker-pkg-build/docker_deb_build.py" \
              "$(which docker_deb_build.py 2>/dev/null || true)"; do
        [[ -x "$p" ]] && { DOCKER_PKG_BUILD="$p"; break; }
    done
    [[ -z "$DOCKER_PKG_BUILD" ]] && {
        log_error "docker_deb_build.py not found. Use --docker-build, set DOCKER_PKG_BUILD, or use --build-mode native."
        exit 1
    }
fi
[[ "$BUILD_MODE" == "docker" && -d "$DOCKER_PKG_BUILD" ]] && DOCKER_PKG_BUILD="$DOCKER_PKG_BUILD/docker_deb_build.py"
[[ "$BUILD_MODE" == "docker" && ! -x "$DOCKER_PKG_BUILD" ]] && { log_error "Not executable: $DOCKER_PKG_BUILD"; exit 1; }

# Handle local source
if [[ -n "$LOCAL_SOURCE" ]]; then
    [[ -d "$LOCAL_SOURCE" ]] || { log_error "Local source not found: $LOCAL_SOURCE"; exit 1; }
    KERNEL_DIR="$(cd "$LOCAL_SOURCE" && pwd)"
    log_info "Using local kernel source: $KERNEL_DIR"
fi

log_step "Configuration:"
[[ -n "$LOCAL_SOURCE" ]] && log_info "  Source:       local ($KERNEL_DIR)" \
                          || log_info "  Repo:         $REPO  branch: $BRANCH"
log_info "  Output:       $OUTPUT_DIR"
log_info "  Distro:       $DISTRO   mode: $BUILD_MODE"
[[ "$BUILD_MODE" == "docker" ]] && log_info "  Docker build: $DOCKER_PKG_BUILD"
[[ -n "$LOCALVERSION" ]]  && log_info "  LOCALVERSION: $LOCALVERSION"
[[ -n "$KVER_EXTRA" ]]    && log_info "  KVER_EXTRA:   $KVER_EXTRA"
[[ -n "$PROFILES" ]]        && log_info "  Profiles:     $PROFILES"
[[ -n "$ENABLE_CONFIGS" ]]  && log_info "  Extra configs: $ENABLE_CONFIGS"
[[ "$SKIP_PREPARE" == true ]] && log_info "  Skip prepare: yes (source already prepared by prepare-source.sh)"
echo

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

# ── Git operations: resolve ref → sync → checkout ────────────────────────────
if [[ -z "$LOCAL_SOURCE" ]]; then
    # Resolve the latest tag remotely before any network I/O (avoids fetching all tags)
    if [[ "$LATEST_TAG" == true ]]; then
        log_step "Finding latest qcom-next-* tag from remote..."
        TAG=$(git ls-remote --tags "$REPO" 'refs/tags/qcom-next-*' \
              | awk '{print $2}' | sed 's|refs/tags/||' | grep -v '\^{}' \
              | sort -V | tail -1)
        [[ -n "$TAG" ]] || { log_error "No qcom-next-* tags found in $REPO"; exit 1; }
        log_info "Latest tag: $TAG"
    fi

    [[ "$CLEAN" == true && -d "$KERNEL_DIR" ]] && { log_step "Cleaning $KERNEL_DIR..."; rm -rf "$KERNEL_DIR"; }

    if [[ ! -d "$KERNEL_DIR" ]]; then
        # ── Fresh clone ───────────────────────────────────────────────────────
        # --single-branch --branch checks out the requested ref directly;
        # no separate checkout step is needed.
        log_step "Cloning $REPO (${TAG:-$BRANCH}, shallow)..."
        git clone --depth 1 --single-branch --branch "${TAG:-$BRANCH}" --no-tags "$REPO" "$KERNEL_DIR"
    else
        # ── Update existing repo ──────────────────────────────────────────────
        [[ -d "$KERNEL_DIR/.git" ]] || { log_error "Not a git repo: $KERNEL_DIR"; exit 1; }
        EXISTING_REMOTE=$(git -C "$KERNEL_DIR" remote get-url origin 2>/dev/null || true)
        if [[ -n "$EXISTING_REMOTE" && "$EXISTING_REMOTE" != "$REPO" ]]; then
            log_error "Repo mismatch at $KERNEL_DIR"
            log_error "  existing remote: $EXISTING_REMOTE"
            log_error "  requested repo:  $REPO"
            log_error "Use --clean to remove and re-clone, or --local-source to use the directory as-is."
            exit 1
        fi
        log_step "Updating kernel source..."
        if [[ -n "$TAG" ]]; then
            git -C "$KERNEL_DIR" fetch --depth 1 --no-tags origin "refs/tags/$TAG:refs/tags/$TAG"
            git -C "$KERNEL_DIR" checkout "$TAG"
        else
            git -C "$KERNEL_DIR" fetch --depth 1 --no-tags origin "$BRANCH"
            git -C "$KERNEL_DIR" checkout -B "$BRANCH" FETCH_HEAD
        fi
    fi

    # Auto-detect LOCALVERSION from tag (applies to both clone and update paths)
    if [[ -n "$TAG" && -z "$LOCALVERSION" ]]; then
        LOCALVERSION="$(_auto_localversion "$TAG")"
        log_info "Auto-detected LOCALVERSION='$LOCALVERSION'"
    fi
fi

cd "$KERNEL_DIR"

# ── Local source: LOCALVERSION detection ─────────────────────────────────────
if [[ -n "$LOCAL_SOURCE" ]]; then
    log_info "Using local source as-is (skipping git checkout)"
    if [[ -z "$LOCALVERSION" ]]; then
        GIT_TAG=$(git describe --tags --exact-match 2>/dev/null || true)
        if [[ -n "$GIT_TAG" ]]; then
            LOCALVERSION="$(_auto_localversion "$GIT_TAG")"
            log_info "Auto-detected LOCALVERSION='$LOCALVERSION' from tag '$GIT_TAG'"
        else
            log_warn "LOCALVERSION not set and no exact git tag found."
            log_warn "Package will be named linux-image-<base-kver>-qcom (no branch/ABI suffix)."
            log_warn "Use --localversion to specify, e.g.: --localversion qcom-next-20260312"
        fi
    fi
fi

# ── Source preparation ────────────────────────────────────────────────────────
# Delegates to prepare-source.sh, which is the single source of truth for
# debian/ injection, config fragment activation, and debian/rules prepare.
# Skipped when --skip-prepare is set (CI mode: prepare-source.sh already ran
# as a dedicated prior step).
if [[ "$SKIP_PREPARE" != true ]]; then
    PREPARE_ARGS=(--source-dir "$KERNEL_DIR" --distro "$DISTRO" --debian-dir "$DEBIAN_DIR")
    [[ -n "$LOCALVERSION" ]]   && PREPARE_ARGS+=(--localversion "$LOCALVERSION")
    [[ -n "$KVER_EXTRA" ]]     && PREPARE_ARGS+=(--kver-extra "$KVER_EXTRA")
    [[ -n "$ENABLE_CONFIGS" ]] && PREPARE_ARGS+=(--enable-configs "$ENABLE_CONFIGS")
    "$SCRIPT_DIR/prepare-source.sh" "${PREPARE_ARGS[@]}"
else
    log_info "Skipping source preparation (--skip-prepare set)."
    [[ -d "$KERNEL_DIR/debian" ]] || {
        log_error "debian/ not found in $KERNEL_DIR — did prepare-source.sh run?"
        exit 1
    }
    [[ -f "$KERNEL_DIR/debian/control" ]] || {
        log_error "debian/control not found — did prepare-source.sh complete successfully?"
        exit 1
    }
fi

# ── Build ────────────────────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
log_step "Building kernel package (mode: $BUILD_MODE)..."
[[ -n "$PROFILES" ]] && log_info "Build profiles: $PROFILES"
echo

case "$BUILD_MODE" in
    docker)
        USE_SUDO=""
        docker ps >/dev/null 2>&1 || {
            log_warn "Docker requires sudo."
            read -rp "Run with sudo? (y/N): " -n 1; echo
            [[ $REPLY =~ ^[Yy]$ ]] || { log_error "Aborted."; exit 1; }
            USE_SUDO="sudo"
        }
        BUILD_CMD=("$DOCKER_PKG_BUILD"
            --skip-gbp
            --no-update-check
            --source-dir "$KERNEL_DIR"
            --output-dir "$OUTPUT_DIR"
            --distro "$DISTRO")
        [[ -n "$PROFILES" ]] && BUILD_CMD+=(--profiles "$PROFILES")
        ${USE_SUDO:+sudo} "${BUILD_CMD[@]}"
        ;;
    native)
        log_info "Running dpkg-buildpackage on host..."
        [[ -n "$PROFILES" ]] && export DEB_BUILD_PROFILES="$PROFILES"
        dpkg-buildpackage -us -uc -b
        find "$(dirname "$KERNEL_DIR")" -maxdepth 1 -name "*.deb" -exec mv -v {} "$OUTPUT_DIR/" \;
        ;;
    sbuild)
        log_info "Running sbuild for $DISTRO..."
        SBUILD_CMD=(sbuild --dist "$DISTRO" --arch arm64 --no-source)
        [[ -n "$PROFILES" ]] && SBUILD_CMD+=(--profiles "$PROFILES")
        "${SBUILD_CMD[@]}"
        ;;
esac

BUILD_STATUS=$?

# Verify .deb files were produced (some tools exit 0 on internal failure)
if [[ $BUILD_STATUS -eq 0 ]]; then
    DEB_COUNT=$(ls "$OUTPUT_DIR"/*.deb 2>/dev/null | wc -l)
    if [[ "$DEB_COUNT" -eq 0 ]]; then
        log_error "Build reported success but no .deb files found in $OUTPUT_DIR"
        exit 1
    fi
fi

if [[ $BUILD_STATUS -eq 0 ]]; then
    echo
    log_step "Build complete!"
    log_info "Packages in: $OUTPUT_DIR"
    ls -lh "$OUTPUT_DIR"/*.deb 2>/dev/null
    echo
    log_info "Install:  sudo dpkg -i $OUTPUT_DIR/linux-image-*-qcom_*.deb"
else
    log_error "Build failed (exit $BUILD_STATUS)"
    exit $BUILD_STATUS
fi
