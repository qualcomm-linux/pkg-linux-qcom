#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

"""Bump the Release refs in ci/build-matrix.json and propose a PR.

For each kernel variant with a Release row, resolve the newest tag of its
Daily row (ref_strategy latest_tag) with ci/scripts/resolve-kernel-ref.sh, the
same lookup daily.yml uses. When that tag's trailing YYYYMMDD is newer than
the Release row's branch_or_tag, the row is bumped to it. A Release row never
moves backwards.

By default this works in a temporary git worktree of <remote>/<base>, so the
current checkout is never touched. The stale Release rows are bumped in one
signed-off commit per kernel (qcom-next and qcom-next-debug share a tag, so
share a commit), pushed to <branch>, and proposed as one PR to <base> with gh.
Merging that PR starts release.yml for the bumped variants;
release-dry-run.yml builds them on the PR first.

Run it by hand as a maintainer: a PR opened with a workflow's GITHUB_TOKEN
would not trigger release-dry-run.yml.

Repository settings needed for --auto-merge:
  - Settings > General > "Allow auto-merge" must be on.
  - main needs branch protection or a ruleset that requires the
    release-dry-run.yml checks and at least one approving review. Without
    required checks, gh either merges the PR at once or refuses to arm
    auto-merge.

Usage:
  ci/scripts/bump-release-tags.py [--auto-merge] [--dry-run] [--yes]
  ci/scripts/bump-release-tags.py --matrix-path PATH [--dry-run] [--yes]

Options:
  --remote NAME       Remote to fetch <base> from and push to (default:
                      origin).
  --base BRANCH       Branch to bump and open the PR against (default: main).
  --branch NAME       Branch to push (default: bump/<newest tag>).
  --auto-merge        Arm auto-merge (merge commit) on the PR, so it merges
                      once the required checks pass and it is approved.
  --dry-run           Show what would change (the diff, in the worktree
                      mode); commit, push and write nothing.
  --matrix-path PATH  Only bump PATH in place: no worktree, git or gh.
  -y, --yes           Do not ask before committing, pushing and opening the
                      PR (or writing PATH).

Before changing anything, the script shows the diff, the commit messages and
what it will push, and asks for confirmation. Progress, including every
command it runs, goes to stderr.

Output:
  One "variant: old -> new" line per bumped Release row, or "up to date",
  followed by the PR URL when one is opened.

Exit codes:
  0  Success, including when everything is up to date or a PR for <branch>
     is already open.
  1  Error.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
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


def newest_tag(bumps):
    return max((new for _, _, new in bumps), key=date_key)


def group_by_tag(bumps):
    """Split bumps into one group per new tag, in matrix order."""
    groups = {}
    for bump in bumps:
        groups.setdefault(bump[2], []).append(bump)
    return list(groups.values())


def apply_bumps(matrix, bumps):
    """Set the Release rows of matrix to the new refs in bumps."""
    for variant, old, new in bumps:
        for row in matrix["deliveries"]:
            if (row["type"] == "Release"
                    and row["kernel_variant"] == variant
                    and row["branch_or_tag"] == old):
                row["branch_or_tag"] = new


def commit_message(group):
    """Return the commit message for a group of bumps to one tag."""
    # qcom-next and qcom-next-debug share a tag; name them once.
    kernels = list(dict.fromkeys(v.removesuffix("-debug") for v, _, _ in group))
    return f"ci: bump {' and '.join(kernels)} Release ref to {group[0][2]}\n"


def github_repo(remote):
    """Return owner/name of the GitHub repository behind remote."""
    url = run(["git", "remote", "get-url", remote], capture=True)
    m = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?/?$", url)
    if not m:
        raise SystemExit(f"ERROR: {remote} ({url}) is not a GitHub remote")
    return m.group(1)


def open_pr(wt, repo, args, base, bumps):
    """Commit bumps on top of base, one commit per tag, and open the PR."""
    branch = args.branch or f"bump/{newest_tag(bumps)}"

    step(f"Checking for an open PR from {branch}")
    existing = run(
        ["gh", "pr", "list", "--repo", repo, "--head", branch,
         "--state", "open", "--json", "url", "--jq", ".[].url"],
        capture=True,
    )
    if existing:
        print(f"PR for {branch} already open: {existing}")
        return

    groups = group_by_tag(bumps)
    messages = [commit_message(g) for g in groups]
    step("Proposed change")
    run(["git", "--no-pager", "diff"], cwd=wt)
    log("")
    log("Commit messages:" if len(messages) > 1 else "Commit message:")
    for message in messages:
        log(textwrap.indent(message, "    "))
    log(f"Push:       {branch} to {args.remote}")
    log(f"PR:         {repo} {args.base} <- {branch}")
    log(f"Auto-merge: {'yes (merge commit)' if args.auto_merge else 'no'}")
    log("")
    if not confirm("Commit, push and open the PR?", args):
        log("Aborted; nothing was committed or pushed.")
        return

    step(f"Committing on {branch}")
    run(["git", "switch", "-q", "-c", branch], cwd=wt)
    for group, message in zip(groups, messages):
        apply_bumps(base, group)
        write_matrix(wt / MATRIX_REL_PATH, base)
        run(["git", "add", MATRIX_REL_PATH], cwd=wt)
        run(["git", "commit", "-q", "-s", "-F", "-"], cwd=wt,
            stdin=message)
    step(f"Pushing {branch} to {args.remote}")
    run(["git", "push", args.remote, f"HEAD:refs/heads/{branch}"], cwd=wt)
    step("Opening the PR")
    if len(messages) == 1:
        fill = ["--fill"]
    else:
        # --fill would title a multi-commit PR after the branch name.
        fill = ["--title", "ci: bump the Release refs",
                "--body", "".join(f"- {m}" for m in messages)]
    url = run(
        ["gh", "pr", "create", "--repo", repo, "--base", args.base,
         "--head", branch, *fill],
        cwd=wt, capture=True,
    )
    print(url)

    if args.auto_merge:
        step("Arming auto-merge")
        run(["gh", "pr", "merge", "--repo", repo, "--auto", "--merge", url])
        print("auto-merge armed")

    step("Looking for other open bump/* PRs")
    others = run(
        ["gh", "pr", "list", "--repo", repo, "--state", "open",
         "--limit", "100", "--json", "headRefName,url",
         "--jq", '.[] | select(.headRefName | startswith("bump/")) | .url'],
        capture=True,
    )
    others = [u for u in others.splitlines() if u != url]
    if others:
        log("Other open bump PRs, superseded by this one:")
        for u in others:
            log(f"  {u}")


def propose(args):
    if not shutil.which("gh"):
        raise SystemExit("ERROR: gh is not installed")
    repo = github_repo(args.remote)
    log(f"Repository: {repo}")
    if not args.dry_run:
        step("Checking gh authentication")
        run(["gh", "auth", "status", "--hostname", "github.com"],
            capture=True)

    step(f"Fetching {args.remote}/{args.base}")
    run(["git", "fetch", "-q", args.remote, args.base])
    with tempfile.TemporaryDirectory(prefix="release-bump-") as tmp:
        wt = Path(tmp) / "wt"
        step(f"Creating a temporary worktree of {args.remote}/{args.base}")
        run(["git", "worktree", "add", "-q", "--detach", str(wt),
             f"{args.remote}/{args.base}"])
        try:
            path = wt / MATRIX_REL_PATH
            base = load_matrix(path)
            matrix = load_matrix(path)
            bumps = bump_matrix(matrix)
            report(bumps)
            if bumps:
                # Only the temporary worktree; nothing is committed yet.
                write_matrix(path, matrix)
            if bumps and args.dry_run:
                step("Proposed change (--dry-run: stopping here)")
                run(["git", "--no-pager", "diff"], cwd=wt)
            elif bumps:
                open_pr(wt, repo, args, base, bumps)
        finally:
            step("Removing the temporary worktree")
            run(["git", "worktree", "remove", "--force", str(wt)])


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
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--base", default="main")
    parser.add_argument("--branch")
    parser.add_argument("--auto-merge", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--matrix-path", type=Path)
    parser.add_argument("-y", "--yes", action="store_true")
    args = parser.parse_args()

    try:
        if args.matrix_path:
            bump_file(args)
        else:
            propose(args)
    except subprocess.CalledProcessError as e:
        log(f"ERROR: {' '.join(map(str, e.cmd))} failed ({e.returncode})")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
