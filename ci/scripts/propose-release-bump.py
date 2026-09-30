#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

"""Bump the Release refs in ci/build-matrix.json.

For each kernel variant with a Release row, resolve the newest tag of its
Daily row (ref_strategy latest_tag) with ci/scripts/resolve-kernel-ref.sh, the
same lookup daily.yml uses. When that tag's trailing YYYYMMDD is newer than
the Release row's branch_or_tag, the row is bumped to it. A Release row never
moves backwards.

Usage:
  ci/scripts/propose-release-bump.py [--matrix-path PATH] [--dry-run] [--yes]

Options:
  --matrix-path PATH  Matrix to bump in place (default: ci/build-matrix.json
                      in this checkout).
  --dry-run           Show what would change; write nothing.
  -y, --yes           Do not ask before writing PATH.

Before writing, the script shows what it would bump and asks for
confirmation. Progress, including every command it runs, goes to stderr.

Output:
  One "variant: old -> new" line per bumped Release row, or "up to date".

Exit codes:
  0  Success, including when everything is up to date.
  1  Error.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
RESOLVE_KERNEL_REF = SCRIPT_DIR / "resolve-kernel-ref.sh"
MATRIX_REL_PATH = "ci/build-matrix.json"

# The snapshot date resolve-kernel-ref.sh sorts tags on.
DATE_SUFFIX = re.compile(r"-(\d{8})$")


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def step(msg):
    log(f"==> {msg}")


def run(cmd, cwd=None, capture=False, stdin=None):
    log(f"    $ {' '.join(map(str, cmd))}")
    sys.stdout.flush()
    result = subprocess.run(
        cmd, cwd=cwd, check=True, text=True, input=stdin,
        stdout=subprocess.PIPE if capture else None,
    )
    return result.stdout.strip() if capture else None


def confirm(prompt, args):
    """Ask before changing anything; --yes answers for the user."""
    if args.yes:
        log(f"{prompt} [y/N] y (--yes)")
        return True
    if not sys.stdin.isatty():
        raise SystemExit("ERROR: not a terminal; pass --yes to proceed")
    try:
        answer = input(f"{prompt} [y/N] ")
    except EOFError:
        answer = ""
    return answer.strip().lower() in ("y", "yes")


def date_key(ref):
    m = DATE_SUFFIX.search(ref)
    return m.group(1) if m else None


def load_matrix(path):
    return json.loads(path.read_text(encoding="utf-8"))


def write_matrix(path, matrix):
    out = json.dumps(matrix, indent=2, ensure_ascii=False) + "\n"
    path.write_text(out, encoding="utf-8")


def bump_matrix(matrix):
    """Bump the stale Release rows of matrix in memory.

    Returns a list of (variant, old, new) tuples, one per bumped row.
    """
    rows = matrix["deliveries"]

    daily = {r["kernel_variant"]: r for r in rows if r["type"] == "Daily"}
    newest = {}
    bumps = []

    for row in rows:
        if row["type"] != "Release":
            continue
        variant = row["kernel_variant"]
        src = daily.get(variant)
        if not src or src.get("ref_strategy") != "latest_tag":
            log(f"{variant}: no latest_tag Daily row, skipping")
            continue

        key = (src["git_clone"], src["tag_pattern"])
        if key not in newest:
            step(f"Resolving the newest {key[1]} tag in {key[0]}")
            newest[key] = run(
                [str(RESOLVE_KERNEL_REF), "--url", key[0],
                 "--latest-tag", key[1]],
                capture=True,
            )
            log(f"    newest: {newest[key]}")
        tag = newest[key]

        old = row["branch_or_tag"]
        old_date = date_key(old)
        log(f"{variant}: Release pins {old}, newest tag is {tag}")
        if old_date is None:
            log(f"{variant}: {old} has no -YYYYMMDD suffix, treating as older")
        elif old_date >= date_key(tag):
            log(f"{variant}: {old_date} >= {date_key(tag)}, up to date")
            continue
        else:
            log(f"{variant}: {old_date} < {date_key(tag)}, bumping")

        row["branch_or_tag"] = tag
        bumps.append((variant, old, tag))

    return bumps


def bump_file(args):
    path = args.matrix_path
    step(f"Checking {path}")
    matrix = load_matrix(path)
    bumps = bump_matrix(matrix)
    report(bumps)
    if not bumps or args.dry_run:
        return
    if not confirm(f"Write {path}?", args):
        log(f"Aborted; {path} is unchanged.")
        return
    write_matrix(path, matrix)
    log(f"Wrote {path}")


def report(bumps):
    for variant, old, new in bumps:
        print(f"{variant}: {old} -> {new}", flush=True)
    if not bumps:
        print("up to date", flush=True)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        epilog="See the header of this script for details.")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--matrix-path", type=Path,
                        default=SCRIPT_DIR.parent.parent / MATRIX_REL_PATH)
    parser.add_argument("-y", "--yes", action="store_true")
    args = parser.parse_args()

    try:
        bump_file(args)
    except subprocess.CalledProcessError as e:
        log(f"ERROR: {' '.join(map(str, e.cmd))} failed ({e.returncode})")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
