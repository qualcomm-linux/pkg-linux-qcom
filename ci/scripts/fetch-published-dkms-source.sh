#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
set -euo pipefail

# Download a DKMS package's source as published in qli, for feeding to
# ci/scripts/check-dkms-module.sh.
#
# Resolves the package by its <stem>-dkms binary name, never by a source
# package name. The stems in ci/build-matrix.json are exactly those binary
# names minus the suffix, while the sources behind them are named
# inconsistently (kgsl, camx-dkms, iris-vpu, audioreach-dkms) and
# iris-vpu-dkms is currently produced by two different ones. apt maps a
# binary to its source through the Binary: field of the Sources index, so a
# deb-src stanza alone is enough and a source rename needs no change here.
#
# Meant for a suite-matched pkg-builder container: the suite, the repository
# URL, its components and its keyring all come from the qli.sources that
# image stages in /tmp, so nothing about qli is spelled out here.
#
# Usage:
#   ci/scripts/fetch-published-dkms-source.sh --module NAME [--version VERSION] [--outdir DIR]
#
# Options:
#   --module NAME      Module to fetch, without the -dkms suffix (e.g. kgsl).
#   --version VERSION  Exact version to fetch. Defaults to what qli serves.
#   --outdir DIR       Where to leave the .dsc and its tarballs (default: .).

MODULE=""; VERSION=""; OUTDIR="."
while [[ $# -gt 0 ]]; do
    case $1 in
        --module)  MODULE="$2";  shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --outdir)  OUTDIR="$2";  shift 2 ;;
        *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    esac
done
[[ -n "$MODULE" ]] || { echo "ERROR: --module NAME is required" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

[[ -f /tmp/qli.sources ]] || {
    echo "ERROR: this image stages no /tmp/qli.sources, so it cannot reach qli" >&2
    echo "       pkg-builder:resolute carries qsc-deb-releases.sources instead," >&2
    echo "       and qli publishes no resolute kernels to check against anyway." >&2
    exit 1
}

# ── Point apt at qli, for sources ────────────────────────────────────────────
# The image configures qli inside the sbuild chroot only, and no image carries
# a deb-src stanza at all. Derive one from the file it stages rather than
# spelling out the URL and components, which is how contrib picks itself up:
# kgsl-dkms and camx-dkms are published there, not in main. The keyring copy
# is removable once qualcomm-linux/docker-pkg-build#54 lands.
install -d /etc/apt/keyrings
cp /tmp/keyrings/*.asc /etc/apt/keyrings/
sed 's/^Types: deb$/Types: deb-src/' /tmp/qli.sources \
    > /etc/apt/sources.list.d/qli-src.sources
apt-get update -qq

# ── Fetch ────────────────────────────────────────────────────────────────────
mkdir -p "$OUTDIR"
PKG="${MODULE}-dkms"
[[ -z "$VERSION" ]] || PKG="$PKG=$VERSION"
# APT::Sandbox::User=root: _apt cannot write under $OUTDIR, so apt would
# disable its download sandbox and warn once per file. We are already root in
# a throwaway container; say so instead of being told.
if ! (cd "$OUTDIR" && apt-get source --download-only \
        -o APT::Sandbox::User=root "$PKG"); then
    echo "ERROR: $PKG is not published in this suite's qli" >&2
    exit 1
fi

mapfile -t DSCS < <(find "$OUTDIR" -maxdepth 1 -name '*.dsc' | sort)
[[ "${#DSCS[@]}" -eq 1 ]] || {
    echo "ERROR: expected one .dsc in $OUTDIR, found ${#DSCS[@]}" >&2
    printf '  | %s\n' "${DSCS[@]}" >&2
    exit 1
}

# apt resolved the binary to a source; check it is the one we asked for, so a
# surprise resolution fails here rather than as a check that selects no legs.
sed -n 's/^Binary: //p' "${DSCS[0]}" | tr ',' '\n' | tr -d ' ' \
    | grep -qx "${MODULE}-dkms" || {
    echo "ERROR: ${DSCS[0]} does not declare ${MODULE}-dkms" >&2
    exit 1
}

echo "Fetched $(basename "${DSCS[0]}") for ${MODULE}-dkms"
