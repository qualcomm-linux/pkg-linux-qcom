#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
set -euo pipefail

# Build a candidate DKMS package's module against the kernel in qli, without
# building a kernel.
#
# The kernel build compiles a module with debian/scripts/bundle-dkms-modules.sh
# against that kernel's staged headers. This runs the same script against the
# same trees as published in qli, so a module that breaks against a kernel
# fails here the way it would fail the kernel's own build.
#
# Meant for a suite-matched pkg-builder container: it needs root, and the
# keyring and qli.sources that image ships in /tmp.
#
# Usage:
#   ci/scripts/check-dkms-module.sh --dsc FILE --module NAME --binpkg NAME
#
# Options:
#   --dsc FILE      Candidate source package, with its tarballs beside it.
#   --module NAME   Module to build, without the -dkms suffix (e.g. kgsl).
#   --binpkg NAME   The kernel's matrix binpkg (e.g. linux-image-qcom-next).
#                   Its linux-headers-* counterpart selects the kernel.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLER="$SCRIPT_DIR/../../debian/scripts/bundle-dkms-modules.sh"

DSC=""; MODULE=""; BINPKG=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --dsc)    DSC="$2";    shift 2 ;;
        --module) MODULE="$2"; shift 2 ;;
        --binpkg) BINPKG="$2"; shift 2 ;;
        *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    esac
done
[[ -f "$DSC" && -n "$MODULE" && "$BINPKG" == linux-image-* ]] || {
    echo "ERROR: --dsc FILE, --module NAME and --binpkg linux-image-* are required" >&2
    exit 1
}
DSC="$(cd "$(dirname "$DSC")" && pwd)/$(basename "$DSC")"
HDRPKG="linux-headers-${BINPKG#linux-image-}"

export DEBIAN_FRONTEND=noninteractive
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── Point apt at qli ─────────────────────────────────────────────────────────
# The image configures qli inside the sbuild chroot only, and we are not using
# sbuild, so point the container's own apt at the keyring and sources it stages
# in /tmp. Removable once qualcomm-linux/docker-pkg-build#54 lands.
install -d /etc/apt/keyrings
cp /tmp/keyrings/*.asc /etc/apt/keyrings/
cp /tmp/qli.sources /etc/apt/sources.list.d/qli.sources
apt-get update -qq

# ── What the kernel's Build-Depends supplies to the bundler ──────────────────
# The kernel build gets these from its generated debian/control. We build no
# kernel, so there is none to read. Removable once
# qualcomm-linux/docker-pkg-build#53 lands. The image already has the rest of
# what the bundler needs by way of build-essential.
apt-get install -y -qq --no-install-recommends \
    bc bison flex libssl-dev libelf-dev dwarves kmod cpio rsync \
    pkg-config dkms >/dev/null

# ── Build and install the candidate ──────────────────────────────────────────
dpkg-source -x "$DSC" "$WORK/src"
apt-get build-dep -y -qq --no-install-recommends "$WORK/src" >/dev/null
(cd "$WORK/src" && dpkg-buildpackage -b -us -uc -d)
# With no kernel installed its postinst has nothing to build for, as in the
# kernel's own build, where it is installed as a Build-Depends.
apt-get install -y -qq --no-install-recommends "$WORK/${MODULE}-dkms_"*.deb >/dev/null

CANDIDATE="$(sed -n 's/^Version: //p' "$DSC")"
INSTALLED="$(dpkg-query -W -f='${Version}' "${MODULE}-dkms")"
[[ "$INSTALLED" == "$CANDIDATE" ]] || {
    echo "ERROR: ${MODULE}-dkms is $INSTALLED, not the candidate $CANDIDATE" >&2
    exit 1
}

# ── Unpack the kernel's headers and image ────────────────────────────────────
# Unpacked, not installed: the bundler reads staged trees, and installing would
# run hooks that have dkms build the module outside of it.
KVER="$(apt-cache show --no-all-versions "$HDRPKG" | sed -n 's/^Depends: //p' \
        | grep -oE 'linux-headers-[^ ,(]+' | head -n1)"
KVER="${KVER#linux-headers-}"
[[ -n "$KVER" ]] || {
    echo "ERROR: could not resolve the kernel release from $HDRPKG" >&2
    exit 1
}

mkdir "$WORK/headers" "$WORK/image" "$WORK/headers-deb" "$WORK/image-deb" "$WORK/stage"
# The _apt user cannot write under the private directory mktemp creates, so apt
# would disable its download sandbox and warn once per package. We are already
# root in a throwaway container; say so instead of being told.
APT_ROOT=(-o APT::Sandbox::User=root)
(cd "$WORK/headers-deb" && apt-get download -qq "${APT_ROOT[@]}" "linux-headers-$KVER")
(cd "$WORK/image-deb" && apt-get download -qq "${APT_ROOT[@]}" "linux-image-$KVER")
dpkg-deb -x "$WORK/headers-deb/"*.deb "$WORK/headers"
dpkg-deb -x "$WORK/image-deb/"*.deb "$WORK/image"
HEADERS_DIR="$WORK/headers/usr/src/linux-headers-$KVER"
[[ -d "$HEADERS_DIR" ]] || {
    echo "ERROR: linux-headers-$KVER does not ship $HEADERS_DIR" >&2
    exit 1
}
# The bundler reads the staged layout, the package ships the merged-usr one.
if [[ -d "$WORK/image/usr/lib/modules" && ! -e "$WORK/image/lib" ]]; then
    ln -s usr/lib "$WORK/image/lib"
fi

echo "$MODULE" > "$WORK/manifest"

echo "Checking ${MODULE}-dkms $CANDIDATE against $KVER"
"$BUNDLER" \
    --kver             "$KVER" \
    --headers-dir      "$HEADERS_DIR" \
    --image-pkg-dir    "$WORK/image" \
    --stage-root       "$WORK/stage" \
    --modules-manifest "$WORK/manifest"
