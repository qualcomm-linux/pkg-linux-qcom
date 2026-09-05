#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
set -e

# Build orchestrator for linux-image-<kver>-qcom Debian/Ubuntu kernel packages.
# Modes: docker (default), native, sbuild

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_REPO="https://github.com/qualcomm-linux/kernel"
DEFAULT_BRANCH="qcom-next"
DEFAULT_DISTRO="trixie"
DEFAULT_FLAVOUR="qcom-next"
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
    --dsc FILE              Build from an existing Debian source package
                            instead of a kernel tree: no clone, no prepare.
                            The .orig.tar.gz and .debian.tar.xz the .dsc
                            names must sit beside it, as build-source-package.sh
                            and CI leave them.

  What to build:
    --source-package        Stop after building the Debian source package
                            (.orig.tar.gz, .dsc, .changes) into the output
                            directory, with build-source-package.sh. The orig
                            tarball is reproducible: see that script. Build
                            binaries from it later with --dsc.

  Version control:
    --flavour NAME          Kernel flavour carried in LOCALVERSION
                            (default: $DEFAULT_FLAVOUR). Ignored with --localversion.
    --localversion SUFFIX   LOCALVERSION suffix (e.g. +qcom-next-20260312-g07f50dc44edd)
                            Derived from the checked-out tag or branch if not given,
                            by prepare-source.sh, the same way CI derives it.
    --kver-extra SUFFIX     Extra suffix appended to the derived KVER, e.g.:
                              --kver-extra -mybuild
                            Results in: 7.0.0-rc2+qcom-next-20260312-g07f50dc44edd-mybuild
                            Useful for CI build IDs or local user builds.

  Build control:
    -d, --distro DISTRO     Target distro: noble|questing|resolute|trixie|sid
                            (default: $DEFAULT_DISTRO)
    --build-mode MODE       docker|native|sbuild (default: $DEFAULT_BUILD_MODE)
    --docker-build PATH     Path to docker_deb_build.py (docker mode)
    --profiles PROFILES     DEB_BUILD_PROFILES (default: none)
    --kernel-config LIST    Extra config fragments, beyond debian/config-available/
                            which is always applied in full. An "intree:" prefix
                            names a path relative to the kernel source root
                            (e.g. intree:arch/arm64/configs/qcom_debug.config)
    --dkms LIST             Comma-separated out-of-tree DKMS modules to build and
                            bundle into linux-image-<KVER>, without the -dkms
                            suffix (e.g. --dkms kgsl,camx). Each entry needs its
                            <name>-dkms package available to the build. Empty by
                            default (bundle nothing).

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
    $0 --latest-tag --kernel-config docker,systemd-boot
    $0 --latest-tag --dkms kgsl
    $0 --latest-tag --source-package
    $0 --dsc kernel-build/trixie/linux-qcom-next_*.dsc

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
DISTRO="$DEFAULT_DISTRO"; BUILD_MODE="$DEFAULT_BUILD_MODE"; FLAVOUR="$DEFAULT_FLAVOUR"
LOCALVERSION=""; KVER_EXTRA=""; PROFILES=""; CLEAN=false
LOCAL_SOURCE=""; ENABLE_CONFIGS="squashfs,systemd-boot,qcom-imsdk,docker,qemu-boot,usb-can"; SKIP_PREPARE=false
DKMS_MODULES=""; DSC=""; SOURCE_PACKAGE=false

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
        --dsc)              DSC="$2";           shift 2 ;;
        --source-package)   SOURCE_PACKAGE=true; shift  ;;
        --docker-build)     DOCKER_PKG_BUILD="$2"; shift 2 ;;
        --flavour)          FLAVOUR="$2";       shift 2 ;;
        --localversion)     LOCALVERSION="$2";  shift 2 ;;
        --kver-extra)       KVER_EXTRA="$2";    shift 2 ;;
        --profiles)         PROFILES="$2";      shift 2 ;;
        --kernel-config)    ENABLE_CONFIGS="$2"; shift 2 ;;
        --dkms)             DKMS_MODULES="$2";  shift 2 ;;
        --enable-configs)   ENABLE_CONFIGS="$2"; shift 2 ;; # deprecated alias
        --build-mode)       BUILD_MODE="$2";    shift 2 ;;
        --skip-prepare)     SKIP_PREPARE=true;  shift   ;;
        --clean)            CLEAN=true;         shift   ;;
        -h|--help)          usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

[[ -z "${OUTPUT_DIR:-}" ]] && OUTPUT_DIR="$OUTPUT_BASE_DIR/$DISTRO"

# Validate distro and build mode
VALID_DISTROS=(noble questing resolute trixie forky sid unstable)
VALID_MODES=(docker native sbuild)
[[ " ${VALID_DISTROS[*]} " =~ " $DISTRO " ]]    || { log_error "Invalid distro: $DISTRO (valid: ${VALID_DISTROS[*]})"; exit 1; }
[[ " ${VALID_MODES[*]} " =~ " $BUILD_MODE " ]]  || { log_error "Invalid build mode: $BUILD_MODE (valid: ${VALID_MODES[*]})"; exit 1; }

# --skip-prepare requires --local-source: the source tree must already exist
# and have been prepared by prepare-source.sh before build-kernel.sh is called.
[[ "$SKIP_PREPARE" == true && -z "$LOCAL_SOURCE" ]] && {
    log_error "--skip-prepare requires --local-source"
    log_error "The source tree must already be prepared by prepare-source.sh before invoking build-kernel.sh --skip-prepare."
    exit 1
}

# --dsc replaces the tree: everything that selects or prepares one is
# meaningless beside it, and so is asking for the source package it already is.
if [[ -n "$DSC" ]]; then
    [[ -z "$LOCAL_SOURCE$TAG" && "$LATEST_TAG" == false && "$SKIP_PREPARE" == false && "$SOURCE_PACKAGE" == false ]] || {
        log_error "--dsc cannot be combined with --local-source, --tag, --latest-tag, --skip-prepare or --source-package"
        exit 1
    }
    [[ -f "$DSC" ]] || { log_error "Source package not found: $DSC"; exit 1; }
    DSC="$(cd "$(dirname "$DSC")" && pwd)/$(basename "$DSC")"
fi

# Locate docker_deb_build.py (docker mode). Building binaries from a tree goes
# through it, so it must exist for that. Building from a .dsc runs sbuild in
# the image directly and only needs it to build the image when the image is
# missing, and --source-package builds no binaries at all, so for those it is
# looked for and not required.
if [[ "$BUILD_MODE" == "docker" && -z "$DOCKER_PKG_BUILD" ]]; then
    for p in "$HOME/docker-pkg-build/docker_deb_build.py" \
              "$SCRIPT_DIR/docker-pkg-build/docker_deb_build.py" \
              "$(which docker_deb_build.py 2>/dev/null || true)"; do
        [[ -x "$p" ]] && { DOCKER_PKG_BUILD="$p"; break; }
    done
    [[ -z "$DOCKER_PKG_BUILD" && -z "$DSC" && "$SOURCE_PACKAGE" == false ]] && {
        log_error "docker_deb_build.py not found. Use --docker-build, set DOCKER_PKG_BUILD, or use --build-mode native."
        exit 1
    }
fi
[[ "$BUILD_MODE" == "docker" && -d "$DOCKER_PKG_BUILD" ]] && DOCKER_PKG_BUILD="$DOCKER_PKG_BUILD/docker_deb_build.py"
[[ "$BUILD_MODE" == "docker" && -n "$DOCKER_PKG_BUILD" && ! -x "$DOCKER_PKG_BUILD" ]] && { log_error "Not executable: $DOCKER_PKG_BUILD"; exit 1; }

# Handle local source
if [[ -n "$LOCAL_SOURCE" ]]; then
    [[ -d "$LOCAL_SOURCE" ]] || { log_error "Local source not found: $LOCAL_SOURCE"; exit 1; }
    KERNEL_DIR="$(cd "$LOCAL_SOURCE" && pwd)"
    log_info "Using local kernel source: $KERNEL_DIR"
fi

log_step "Configuration:"
if [[ -n "$DSC" ]]; then
    log_info "  Source:       $DSC"
elif [[ -n "$LOCAL_SOURCE" ]]; then
    log_info "  Source:       local ($KERNEL_DIR)"
else
    log_info "  Repo:         $REPO  branch: $BRANCH"
fi
log_info "  Output:       $OUTPUT_DIR"
[[ "$SOURCE_PACKAGE" == true ]] && log_info "  Building:     source package only"
log_info "  Distro:       $DISTRO   mode: $BUILD_MODE"
[[ "$BUILD_MODE" == "docker" && -n "$DOCKER_PKG_BUILD" ]] && log_info "  Docker build: $DOCKER_PKG_BUILD"
[[ -n "$PROFILES" ]]        && log_info "  Profiles:     $PROFILES"
# The rest describes preparing a tree, which a .dsc has already had done.
if [[ -z "$DSC" ]]; then
    [[ -n "$LOCALVERSION" ]]  && log_info "  LOCALVERSION: $LOCALVERSION" \
                              || log_info "  Flavour:      $FLAVOUR"
    [[ -n "$KVER_EXTRA" ]]    && log_info "  KVER_EXTRA:   $KVER_EXTRA"
    [[ -n "$ENABLE_CONFIGS" ]]  && log_info "  Extra configs: $ENABLE_CONFIGS"
    [[ -n "$DKMS_MODULES" ]]    && log_info "  DKMS modules: $DKMS_MODULES"
    [[ "$SKIP_PREPARE" == true ]] && log_info "  Skip prepare: yes (source already prepared by prepare-source.sh)"
fi
echo

# ── Git operations: resolve ref → sync → checkout ────────────────────────────
if [[ -n "$DSC" ]]; then
    : # No tree: the source package is the source.
elif [[ -z "$LOCAL_SOURCE" ]]; then
    # Resolve the latest tag remotely before any network I/O (avoids fetching
    # all tags). The same script CI uses, so "latest" means the same thing
    # here: the newest trailing date, not the highest kernel version.
    if [[ "$LATEST_TAG" == true ]]; then
        log_step "Finding latest qcom-next-* tag from remote..."
        TAG=$("$SCRIPT_DIR/ci/scripts/resolve-kernel-ref.sh" --url "$REPO" --latest-tag 'qcom-next-*')
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
else
    log_info "Using local source as-is (skipping git checkout)"
fi

[[ -n "$DSC" ]] || cd "$KERNEL_DIR"

# ── Source preparation ────────────────────────────────────────────────────────
# Delegates to prepare-source.sh, which is the single source of truth for
# debian/ injection, config fragment activation, version derivation, and
# debian/rules prepare. Nothing about the version is decided here: an explicit
# --localversion is passed through, and otherwise prepare-source.sh derives
# it from the checkout the way CI does.
# Skipped when --skip-prepare is set (CI mode: prepare-source.sh already ran
# as a dedicated prior step), and when there is no tree to prepare.
if [[ -n "$DSC" ]]; then
    :
elif [[ "$SKIP_PREPARE" != true ]]; then
    PREPARE_ARGS=(--source-dir "$KERNEL_DIR" --distro "$DISTRO" --debian-dir "$DEBIAN_DIR"
                  --flavour "$FLAVOUR")
    [[ -n "$LOCALVERSION" ]]   && PREPARE_ARGS+=(--localversion "$LOCALVERSION")
    [[ -n "$KVER_EXTRA" ]]     && PREPARE_ARGS+=(--kver-extra "$KVER_EXTRA")
    [[ -n "$ENABLE_CONFIGS" ]] && PREPARE_ARGS+=(--kernel-config "$ENABLE_CONFIGS")
    [[ -n "$DKMS_MODULES" ]]   && PREPARE_ARGS+=(--dkms "$DKMS_MODULES")
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

# ── Source package ───────────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
if [[ "$SOURCE_PACKAGE" == true ]]; then
    log_step "Building the source package into $OUTPUT_DIR..."
    "$SCRIPT_DIR/build-source-package.sh" --source-dir "$KERNEL_DIR" --output-dir "$OUTPUT_DIR"
    echo
    log_info "Build binaries from it with:"
    log_info "  $0 --dsc $OUTPUT_DIR/$(cd "$OUTPUT_DIR" && ls -- *.dsc | tail -1) --distro $DISTRO"
    exit 0
fi

# ── Build ────────────────────────────────────────────────────────────────────
log_step "Building kernel package (mode: $BUILD_MODE)..."
[[ -n "$PROFILES" ]] && log_info "Build profiles: $PROFILES"
echo

# Every mode builds either the prepared tree or the source package. The
# source-package path is the one CI takes for every suite, so it is the one to
# use when a local build must produce what CI produced: same .dsc in, same
# binaries out.
case "$BUILD_MODE" in
    docker)
        USE_SUDO=""
        docker ps >/dev/null 2>&1 || {
            log_warn "Docker requires sudo."
            read -rp "Run with sudo? (y/N): " -n 1; echo
            [[ $REPLY =~ ^[Yy]$ ]] || { log_error "Aborted."; exit 1; }
            USE_SUDO="sudo"
        }
        if [[ -n "$DSC" ]]; then
            # docker_deb_build.py builds from a tree only, so the .dsc is
            # handed to sbuild inside the same builder image directly, with
            # the same sbuild flags docker_deb_build.py uses. The image is
            # named as docker-pkg-build names it; when it is missing,
            # docker_deb_build.py --rebuild builds it from its Dockerfile.
            DOCKER_IMAGE="ghcr.io/qualcomm-linux/pkg-builder:$DISTRO"
            ${USE_SUDO:+sudo} docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1 || {
                [[ -n "$DOCKER_PKG_BUILD" ]] || {
                    log_error "Builder image $DOCKER_IMAGE is not present, and docker_deb_build.py was not found to build it."
                    log_error "Pull the image, or point --docker-build at a docker-pkg-build checkout."
                    exit 1
                }
                log_info "Builder image $DOCKER_IMAGE not present; building it with docker-pkg-build..."
                ${USE_SUDO:+sudo} "$DOCKER_PKG_BUILD" --no-update-check --rebuild -d "$DISTRO"
            }
            # The .dsc's directory is mounted read-only so sbuild can read the
            # tarballs it names; results go to the output mount.
            SBUILD_CMD="sbuild --chroot-mode=unshare --build-dep-resolver=aptitude"
            SBUILD_CMD+=" --no-clean-source --build-dir=/workspace/output"
            SBUILD_CMD+=" --host=arm64 --build=arm64 --dist=$DISTRO --no-run-lintian"
            [[ -n "$PROFILES" ]] && SBUILD_CMD+=" --profiles=$PROFILES"
            SBUILD_CMD+=" /workspace/source/$(basename "$DSC")"
            ${USE_SUDO:+sudo} docker run --rm --privileged \
                -v "$(dirname "$DSC"):/workspace/source:ro" \
                -v "$OUTPUT_DIR:/workspace/output:Z" \
                -w /workspace/output \
                "$DOCKER_IMAGE" bash -c "$SBUILD_CMD"
        else
            BUILD_CMD=("$DOCKER_PKG_BUILD"
                --skip-gbp
                --no-update-check
                --source-dir "$KERNEL_DIR"
                --output-dir "$OUTPUT_DIR"
                --distro "$DISTRO")
            [[ -n "$PROFILES" ]] && BUILD_CMD+=(--profiles "$PROFILES")
            ${USE_SUDO:+sudo} "${BUILD_CMD[@]}"
        fi
        ;;
    native)
        log_info "Running dpkg-buildpackage on host..."
        [[ -n "$PROFILES" ]] && export DEB_BUILD_PROFILES="$PROFILES"
        if [[ -n "$DSC" ]]; then
            # Unpack into the output directory, so dpkg-buildpackage's ../
            # is the output directory and the .deb files land there.
            BUILD_TREE="$OUTPUT_DIR/$(basename "$DSC" .dsc)"
            rm -rf "$BUILD_TREE"
            dpkg-source -x "$DSC" "$BUILD_TREE"
            (cd "$BUILD_TREE" && dpkg-buildpackage -us -uc -b)
        else
            dpkg-buildpackage -us -uc -b
            find "$(dirname "$KERNEL_DIR")" -maxdepth 1 -name "*.deb" -exec mv -v {} "$OUTPUT_DIR/" \;
        fi
        ;;
    sbuild)
        log_info "Running sbuild for $DISTRO..."
        SBUILD_CMD=(sbuild --dist "$DISTRO" --arch arm64)
        [[ -n "$PROFILES" ]] && SBUILD_CMD+=(--profiles "$PROFILES")
        if [[ -n "$DSC" ]]; then
            # sbuild takes a .dsc directly and writes beside its cwd.
            (cd "$OUTPUT_DIR" && "${SBUILD_CMD[@]}" "$DSC")
        else
            "${SBUILD_CMD[@]}" --no-source
        fi
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
    log_info "Install:  sudo dpkg -i $OUTPUT_DIR/linux-image-*_*_arm64.deb"
else
    log_error "Build failed (exit $BUILD_STATUS)"
    exit $BUILD_STATUS
fi
