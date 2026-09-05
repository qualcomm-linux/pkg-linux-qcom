#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
set -euo pipefail

# Build a Debian source package from a prepared kernel tree.
#
# Takes a kernel checkout that prepare-source.sh has already injected debian/
# into, and produces in an output directory the .orig.tar.gz, .debian.tar.xz,
# .dsc and .changes that a binary build -- local, Debusine, or sbuild in a
# container -- starts from.
#
# The orig tarball is a function of the commit and nothing else. It is written
# with git archive, which sets every entry's mtime to the commit time and its
# owner to root, and compressed with gzip -n, which writes no timestamp. Two
# runs on one commit therefore produce one tarball, byte for byte, and two
# matrix entries that share a source package and upstream version -- trixie
# and forky, differing only in Debian revision -- share one orig, which is
# what an archive holding both requires.
#
# The upstream version names the commit (the ~g<sha> field), so the archived
# commit is checked against it: an orig named for one commit must hold that
# commit's tree. The tree is also checked against the commit before the
# package is built, because dpkg-source would otherwise fold any stray file
# into an automatic patch and the package would no longer describe the
# commit its version names.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $0 --source-dir DIR --output-dir DIR [OPTIONS]

Build a Debian source package (.orig.tar.gz, .debian.tar.xz, .dsc, .changes)
from a kernel tree that prepare-source.sh has already prepared.

OPTIONS:
  Required:
    -s, --source-dir DIR      Prepared kernel source directory: a git checkout
                              with debian/ injected and debian/changelog
                              generated.
    -o, --output-dir DIR      Where the source package is written. Created if
                              missing. An orig tarball already there for this
                              upstream version is rebuilt and must come out
                              identical.

  Options:
    --commit SHA              Commit to archive as the upstream source
                              (default: HEAD of --source-dir). Must be the
                              commit the package version names.
    --write-fields FILE       Also write KEY=VALUE lines describing the result
                              to FILE, for a caller that goes on to use it:
                              SRCPKG_NAME, SRCPKG_VERSION, UPSTREAM_VERSION,
                              CHANGES, DSC, ORIG, ORIG_SHA256.
    -h, --help                Show this help

EXAMPLES:
    # After prepare-source.sh, from the repository root:
    $0 --source-dir kernel-source --output-dir kernel-build/source

    # Then build binaries from it:
    ./build-kernel.sh --dsc kernel-build/source/linux-qcom-next_*.dsc --distro trixie
EOF
    exit 1
}

SOURCE_DIR=""
OUTPUT_DIR=""
COMMIT=""
FIELDS_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--source-dir)   SOURCE_DIR="$2";  shift 2 ;;
        -o|--output-dir)   OUTPUT_DIR="$2";  shift 2 ;;
        --commit)          COMMIT="$2";      shift 2 ;;
        --write-fields)    FIELDS_FILE="$2"; shift 2 ;;
        -h|--help)         usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# ── Validate inputs ───────────────────────────────────────────────────────────
[[ -n "$SOURCE_DIR" ]] || { log_error "--source-dir is required"; usage; }
[[ -n "$OUTPUT_DIR" ]] || { log_error "--output-dir is required"; usage; }
[[ -d "$SOURCE_DIR" ]] || { log_error "Source directory not found: $SOURCE_DIR"; exit 1; }
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"

[[ -f "$SOURCE_DIR/debian/changelog" ]] || {
    log_error "No debian/changelog in $SOURCE_DIR"
    log_error "Run $SCRIPT_DIR/prepare-source.sh --source-dir $SOURCE_DIR first."
    exit 1
}
grep -qF '@PKGVER@' "$SOURCE_DIR/debian/changelog" && {
    log_error "debian/changelog in $SOURCE_DIR is still the template."
    log_error "Run $SCRIPT_DIR/prepare-source.sh --source-dir $SOURCE_DIR first."
    exit 1
}

for tool in git dpkg-parsechangelog dpkg-source dpkg-genchanges gzip; do
    command -v "$tool" >/dev/null || { log_error "$tool not found; install dpkg-dev and git"; exit 1; }
done

git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    log_error "$SOURCE_DIR is not a git checkout; the orig tarball is archived from a commit."
    exit 1
}

# ── Read the package identity from the changelog ─────────────────────────────
# The changelog is what prepare-source.sh generated and what the .dsc will be
# built from, so it is the only source of the name and version here. The sed
# filters keep the values to what Debian policy allows in a package name and
# version, as debusine-action does, so they are safe in filenames.
PKG=$(dpkg-parsechangelog -l "$SOURCE_DIR/debian/changelog" -SSource | sed 's/[^a-z0-9.+-]//g')
VER=$(dpkg-parsechangelog -l "$SOURCE_DIR/debian/changelog" -SVersion | sed 's/[^A-Za-z0-9.+~:-]//g')
[[ -n "$PKG" && -n "$VER" ]] || { log_error "Could not read Source and Version from debian/changelog"; exit 1; }
UPSTREAM_VER="${VER%-*}"
[[ "$UPSTREAM_VER" != "$VER" ]] || {
    log_error "Version $VER has no Debian revision; a 3.0 (quilt) package needs one."
    exit 1
}

# ── Resolve the commit and check it against the version ──────────────────────
[[ -n "$COMMIT" ]] || COMMIT=HEAD
COMMIT_SHA=$(git -C "$SOURCE_DIR" rev-parse --verify "${COMMIT}^{commit}") || {
    log_error "Not a commit in $SOURCE_DIR: $COMMIT"
    exit 1
}

# debian/rules spells the commit into the upstream version as ~g<12 hex>. An
# orig named for that commit must hold that commit's tree, so the two are
# checked against each other rather than trusted to agree. A version without
# the field (an explicit --localversion with no snapshot) names no commit, in
# which case there is nothing to check and the tarball is only as
# reproducible as the caller's choice of commit.
if [[ "$UPSTREAM_VER" =~ ~g([0-9a-f]{12}) ]]; then
    VERSION_SHA="${BASH_REMATCH[1]}"
    [[ "$COMMIT_SHA" == "$VERSION_SHA"* ]] || {
        log_error "Version $VER names commit $VERSION_SHA, but $COMMIT is $COMMIT_SHA."
        log_error "Re-run prepare-source.sh on this checkout, or pass --commit $VERSION_SHA."
        exit 1
    }
else
    log_warn "Version $VER names no commit; the orig tarball is archived from $COMMIT_SHA."
fi

# ── Check the tree against the commit ────────────────────────────────────────
# dpkg-source compares the tree with the orig, so anything outside debian/
# that differs from the commit -- an in-tree build's objects, an edit not
# committed -- would become an automatic patch or abort the build. Refuse it
# here with the list and the command that cleans it, rather than let
# dpkg-source report it one file at a time.
log_step "Checking $SOURCE_DIR matches $COMMIT_SHA outside debian/..."
if [[ "$COMMIT_SHA" != "$(git -C "$SOURCE_DIR" rev-parse HEAD)" ]]; then
    log_error "HEAD of $SOURCE_DIR is not $COMMIT; check out the commit the package names."
    exit 1
fi
STRAY=$(git -C "$SOURCE_DIR" status --porcelain --ignored -- . ':(exclude)debian' | head -20)
[[ -z "$STRAY" ]] || {
    log_error "$SOURCE_DIR differs from commit $COMMIT_SHA outside debian/:"
    echo "$STRAY"
    log_error "The source package must describe the commit its version names."
    log_error "Clean the tree first, keeping the injected packaging:"
    log_error "  git -C $SOURCE_DIR checkout -- . && git -C $SOURCE_DIR clean -xdf -- . ':(exclude)debian'"
    exit 1
}

# ── Write the orig tarball ───────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
ORIG="$OUTPUT_DIR/${PKG}_${UPSTREAM_VER}.orig.tar.gz"
DSC="$OUTPUT_DIR/${PKG}_${VER}.dsc"
CHANGES="$OUTPUT_DIR/${PKG}_${VER}_source.changes"

PREVIOUS_ORIG_SHA256=""
[[ -f "$ORIG" ]] && PREVIOUS_ORIG_SHA256=$(sha256sum "$ORIG" | cut -d' ' -f1)

log_step "Writing $ORIG from commit $COMMIT_SHA..."
# --format=tar piped through gzip rather than --format=tar.gz: git's own
# gzip is also deterministic, but this spells out which compressor decides
# the bytes. The bytes depend on the gzip implementation, so every build
# that must agree on a checksum runs this in the same builder image.
git -C "$SOURCE_DIR" archive --format=tar --prefix="${PKG}-${UPSTREAM_VER}/" "$COMMIT_SHA" \
    | gzip -9n > "$ORIG.tmp"
mv "$ORIG.tmp" "$ORIG"
ORIG_SHA256=$(sha256sum "$ORIG" | cut -d' ' -f1)
log_info "  sha256: $ORIG_SHA256"

if [[ -n "$PREVIOUS_ORIG_SHA256" && "$PREVIOUS_ORIG_SHA256" != "$ORIG_SHA256" ]]; then
    # The file that was there carried the same name and so claimed the same
    # commit. It cannot have been the same tarball, so something about how
    # it was made differs from this run -- which is what this script exists
    # to rule out.
    log_error "An orig tarball for $PKG $UPSTREAM_VER already existed with sha256 $PREVIOUS_ORIG_SHA256"
    log_error "and rebuilding it from $COMMIT_SHA gave $ORIG_SHA256."
    log_error "Two files with this name must be one file; find what changed between the two builds."
    exit 1
fi

# ── Build the .dsc and .changes ──────────────────────────────────────────────
# dpkg-source -b writes into the current directory and finds the orig there,
# so it runs from the output directory. dpkg-genchanges reads debian/ from
# the source tree and is told where the files are and where to write.
log_step "Building the source package..."
rm -f "$DSC" "$OUTPUT_DIR/${PKG}_${VER}.debian.tar."* "$CHANGES"
(cd "$OUTPUT_DIR" && dpkg-source -b "$SOURCE_DIR")
(cd "$SOURCE_DIR" && dpkg-genchanges -S -sa -u"$OUTPUT_DIR" -O"$CHANGES" >/dev/null)

[[ -f "$DSC" && -f "$CHANGES" ]] || {
    log_error "Expected $DSC and $CHANGES to exist after the build"
    exit 1
}

echo
log_step "Source package complete."
log_info "  $CHANGES"
grep -A100 '^Checksums-Sha256:' "$CHANGES" | sed -n '2,/^[A-Z]/{/^ /p}' | sed 's/^/  /'

if [[ -n "$FIELDS_FILE" ]]; then
    cat > "$FIELDS_FILE" <<EOF
SRCPKG_NAME=$PKG
SRCPKG_VERSION=$VER
UPSTREAM_VERSION=$UPSTREAM_VER
CHANGES=$CHANGES
DSC=$DSC
ORIG=$ORIG
ORIG_SHA256=$ORIG_SHA256
EOF
    log_info "Fields written to $FIELDS_FILE"
fi
