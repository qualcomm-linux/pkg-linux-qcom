#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
"""Validate and select entries from the kernel delivery matrix.

ci/build-matrix.yaml holds one entry per generated package: a single named
build, one delivery type, and one suite. Nothing here
expands or derives anything -- the matrix is already flat, and each entry
states its own debian_revision. This script validates the whole document,
selects the entries a caller asked for, and prints them.

The document is validated in full on every invocation, not just the selected
entries, so a typo in a Release entry fails the daily build too rather than
lying in wait until someone runs a release.

Usage:
  ci/scripts/resolve-matrix.py --type Daily
  ci/scripts/resolve-matrix.py --type Daily --build qcom-next-trixie
  ci/scripts/resolve-matrix.py --type Daily --build qcom-next-trixie,qcom-next-forky
  ci/scripts/resolve-matrix.py --type Release --flavour qcom-next
  ci/scripts/resolve-matrix.py --type Daily --family ubuntu --allow-empty
  ci/scripts/resolve-matrix.py --type Daily --build qcom-next-trixie \\
      --field debian_revision

Options:
  --type TYPE                Delivery type to select (Daily or Release).
                               Required.
  --build NAMES              Select only these builds by name, comma-separated.
                               A name identifies one build, so this is the way
                               to ask for a specific set of them.
  --flavour FLAVOURS         Select only these flavours, comma-separated. A
                               flavour spans its suites, so this asks for one
                               kernel everywhere it is built.
  --suite SUITES             Select only these suites, comma-separated.
  --family FAMILY            Select only the builds taking one build path,
                               debian or ubuntu. Derived from suite, so it
                               selects by how a build is built rather than by
                               naming every suite that is built that way.
  --allow-empty              Print [] rather than failing when the filters
                               select nothing. For a caller asking each family
                               for the same selection, where one of them
                               having nothing to build is an ordinary answer.
  --field NAME               Print just this field of the single selected
                               entry, unquoted. Errors unless exactly one
                               entry matches.
  --matrix-file FILE         Matrix path (default: ci/build-matrix.yaml
                               relative to CWD).

  Filters combine: an entry must match every filter given. Every name in a
  filter must match at least one entry of the selected type, so a typo or a
  stale name fails instead of quietly narrowing the build set. That check is
  per filter, so --allow-empty still rejects a name that matches nothing.

Output:
  Without --field, a compact JSON array of the selected entries, ready for a
  GitHub Actions matrix `include`. Each entry carries a derived family field
  naming its build path. kernel_config and dkms are joined into the
  comma-separated strings that the build workflows' kernel-config and dkms
  inputs, and prepare-source.sh's --kernel-config and --dkms, expect; every
  other field is passed through as written.

  With --field, the named field's value alone, so a workflow step can capture
  it directly.

Exit codes:
  0  Success, at least one entry selected.
  1  Error (invalid arguments, matrix validation failure, no matching entry,
     or --field matching more than one entry).
"""

import argparse
import json
import re
import sys
from collections import defaultdict

try:
    import yaml
except ImportError:
    sys.exit(
        "ERROR: PyYAML is required to read the delivery matrix.\n"
        "       Install it with 'apt-get install python3-yaml' or 'pip install pyyaml'."
    )

DEFAULT_MATRIX_FILE = "ci/build-matrix.yaml"

DELIVERY_TYPES = ("Daily", "Release")
REF_STRATEGIES = ("latest_tag", "branch_tip", "pinned_ref")

# Which build path a suite takes. Debian-family suites are built by Debusine;
# everything else is built in a suite-matched docker container on the
# self-hosted runner. The two paths are different workflows with different
# runners, containers and publish steps, so a caller selects entries by family
# and calls the one workflow that builds them -- rather than every build leg
# starting both and skipping one.
DEBIAN_SUITES = ("trixie", "forky", "sid", "unstable")
FAMILIES = ("debian", "ubuntu")


def family_for(suite):
    """Return the build family a suite belongs to."""
    return "debian" if suite in DEBIAN_SUITES else "ubuntu"

# A delivery type constrains how its kernel ref is chosen: a Daily build tracks
# something moving, a Release build is pinned to an immutable ref.
REF_STRATEGIES_FOR_TYPE = {
    "Daily": ("latest_tag", "branch_tip"),
    "Release": ("pinned_ref",),
}

REQUIRED_STRING_FIELDS = (
    "name",
    "type",
    "suite",
    "flavour",
    "git_clone",
    "branch_or_tag",
    "ref_strategy",
    "srcpkg",
    "binpkg",
    "debian_revision",
)

OPTIONAL_STRING_FIELDS = (
    "tag_pattern",
    "target_workspace",
    "localversion",
    "kver_extra",
    "debusine_parent_workspace",
)

KNOWN_FIELDS = frozenset(
    REQUIRED_STRING_FIELDS + OPTIONAL_STRING_FIELDS + ("kernel_config", "dkms")
)

# Everything about what is built is anchored on flavour, not on the build's
# name. The flavour is the kernel's own identity: it becomes the LOCALVERSION
# suffix, so two flavours built from one ref produce distinct kernel releases
# whose linux-image packages install alongside each other. A build's name only
# labels it in CI -- the Actions job, and what a dispatch asks for -- and
# carries no packaging meaning.

# Fields that identify the flavour itself rather than one of its build legs.
# Every entry for a flavour must agree on them, because they decide what the
# package is; the entries only differ in where it is delivered.
FLAVOUR_IDENTITY_FIELDS = ("srcpkg", "binpkg", "kernel_config")

# Fields a flavour may vary between suites but not within one. The out-of-tree
# module set depends on which <name>-dkms packages the target archive has, so
# it is a property of the flavour in a suite rather than of the flavour. A
# suite's Daily and Release must still agree: a Daily that bundles a different
# module set from the Release it precedes is not testing what will ship.
SUITE_IDENTITY_FIELDS = ("dkms",)

# Fields deciding which kernel tree is built. All entries for one flavour and
# delivery type build the same source, so a stale suite cannot quietly ship a
# different kernel from its siblings.
REF_FIELDS = ("git_clone", "branch_or_tag", "ref_strategy", "tag_pattern")

NAME_RE = re.compile(r"^[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?$")

# The dispatch forms of daily.yml and release.yml take one builds field, where
# "all" means every entry of the delivery type and anything else is a list of
# names. A build actually called all would be unreachable through them, so the
# matrix may not define one.
RESERVED_NAMES = ("all",)

# A Debian revision: no hyphen (that would start a new revision component) and
# none of the characters dpkg rejects in a version.
REVISION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.+~]*$")

# An "intree:" entry names a fragment shipped by the kernel source, as a path
# relative to the kernel source root. A bare entry names a fragment in
# debian/config-available/, with or without its .config extension.
INTREE_PATH_RE = re.compile(r"^([A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.config$")
BARE_FRAGMENT_RE = re.compile(r"^[A-Za-z0-9_.-]+$")

# A dkms entry is a package name stem: the build wants <name>-dkms available,
# and generates both the Build-Depends entry and the debian/dkms-modules
# manifest from it. Same shape debian/rules enforces at prepare time, checked
# here so a typo fails before a runner is claimed rather than mid-build.
DKMS_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9+.-]*$")


def fragment_basename(fragment):
    """Filename a fragment lands under in debian/config/, minus .config.

    Every fragment is copied into debian/config/ under its basename, so
    arch/arm64/configs/hardening.config and kernel/configs/hardening.config
    collide there even though the entries differ.
    """
    return fragment.removeprefix("intree:").rsplit("/", 1)[-1].removesuffix(".config")


def check_kernel_config(entry, report):
    """Validate one entry's kernel_config list."""
    fragments = entry.get("kernel_config")
    if not isinstance(fragments, list):
        report("kernel_config must be a list")
        return
    if any(not isinstance(f, str) or not f for f in fragments):
        report("kernel_config must contain only non-empty strings")
        return
    if any("," in f for f in fragments):
        report(
            "kernel_config entries must not contain commas; "
            "use one list element per fragment"
        )
        return
    if len(set(fragments)) != len(fragments):
        report("kernel_config must not contain duplicates")

    for fragment in fragments:
        if fragment.startswith("intree:"):
            path = fragment.removeprefix("intree:")
            traversal = path == ".." or path.startswith("../") or "/../" in path
            if not INTREE_PATH_RE.match(path) or traversal or path.endswith("/.."):
                report(
                    f"intree: entry '{fragment}' must be a kernel-source-relative "
                    "path ending in .config "
                    "(e.g. intree:arch/arm64/configs/qcom_debug.config)"
                )
        elif not BARE_FRAGMENT_RE.match(fragment):
            report(
                f"kernel_config entry '{fragment}' must be a fragment name from "
                "debian/config-available/ or an intree: path"
            )

    basenames = [fragment_basename(f) for f in fragments]
    if len(set(basenames)) != len(basenames):
        report("kernel_config entries must not resolve to the same fragment filename")


def check_dkms(entry, report):
    """Validate one entry's dkms list.

    An empty list is meaningful: it bundles nothing, as opposed to leaving the
    field out, which the matrix does not allow.
    """
    modules = entry.get("dkms")
    if not isinstance(modules, list):
        report("dkms must be a list")
        return
    if any(not isinstance(m, str) or not m for m in modules):
        report("dkms must contain only non-empty strings")
        return
    if len(set(modules)) != len(modules):
        report("dkms must not contain duplicates")

    for module in modules:
        if module.endswith("-dkms"):
            report(
                f"dkms entry '{module}' must omit the -dkms suffix "
                f"(use '{module.removesuffix('-dkms')}')"
            )
        elif not DKMS_NAME_RE.match(module):
            report(f"dkms entry '{module}' must be a package name stem, e.g. kgsl")


def check_entry(entry, report):
    """Validate one delivery entry in isolation."""
    for field in REQUIRED_STRING_FIELDS:
        value = entry.get(field)
        if not isinstance(value, str) or not value:
            report(f"missing or invalid {field}")

    for field in OPTIONAL_STRING_FIELDS:
        if field in entry and not isinstance(entry[field], str):
            report(f"invalid {field}")

    for field in sorted(set(entry) - KNOWN_FIELDS):
        report(f"unknown field {field}")

    for field in ("name", "suite", "flavour"):
        value = entry.get(field)
        if isinstance(value, str) and not NAME_RE.match(value):
            report(f"{field} must use lowercase letters, digits, and internal hyphens")

    if entry.get("name") in RESERVED_NAMES:
        report(
            f"name {entry['name']} is reserved by the build workflows' dispatch "
            "form, where it selects every entry rather than one of them"
        )

    check_kernel_config(entry, report)
    check_dkms(entry, report)

    delivery_type = entry.get("type")
    if delivery_type not in DELIVERY_TYPES:
        report("type must be Daily or Release")

    ref_strategy = entry.get("ref_strategy")
    if ref_strategy not in REF_STRATEGIES:
        report("ref_strategy must be " + ", ".join(REF_STRATEGIES))
    elif delivery_type in REF_STRATEGIES_FOR_TYPE:
        allowed = REF_STRATEGIES_FOR_TYPE[delivery_type]
        if ref_strategy not in allowed:
            report(
                f"{delivery_type} entries must use "
                + " or ".join(f"ref_strategy={s}" for s in allowed)
            )

    if ref_strategy == "latest_tag":
        if not entry.get("tag_pattern"):
            report("missing or invalid tag_pattern")
    elif "tag_pattern" in entry:
        report("tag_pattern is only valid with ref_strategy=latest_tag")

    if delivery_type == "Release":
        if not entry.get("target_workspace"):
            report("missing or invalid target_workspace")
        # Promotion runs through Debusine, and only the Debian family is built
        # there. An Ubuntu Release entry would build the package and then have
        # no workspace to promote it from, publishing to the daily S3 path and
        # reporting success without ever releasing anything.
        suite = entry.get("suite")
        if isinstance(suite, str) and family_for(suite) != "debian":
            report(
                f"Release entries must target a Debian suite, not {suite}; "
                "promotion runs through Debusine, which builds "
                + ", ".join(DEBIAN_SUITES)
            )
    elif "target_workspace" in entry:
        report("target_workspace is only valid for Release")

    revision = entry.get("debian_revision")
    if isinstance(revision, str) and revision:
        if not REVISION_RE.match(revision):
            report(
                f'debian_revision "{revision}" is not a valid Debian revision '
                "(letters, digits, and . + ~ only, starting with a letter or digit)"
            )
        # A trailing ~ sorts a version below the same version without it, so a
        # Daily always sorts below the Release it will be superseded by.
        elif delivery_type == "Daily" and not revision.endswith("~"):
            report(f'debian_revision "{revision}" must end in ~ for a Daily entry')
        elif delivery_type == "Release" and revision.endswith("~"):
            report(f'debian_revision "{revision}" must not end in ~ for a Release entry')


def describe(entry, index):
    """Label an entry in an error message by what identifies it to a reader."""
    if not isinstance(entry, dict):
        return f"entry {index}"
    parts = [
        str(entry[field])
        for field in ("name", "type", "suite")
        if isinstance(entry.get(field), str)
    ]
    return f"entry {index} ({'/'.join(parts)})" if parts else f"entry {index}"


def check_consistency(builds, errors):
    """Validate the invariants that span entries.

    Entries are written out in full, so the matrix can state a flavour twice
    and disagree with itself. These checks are what makes that duplication
    safe to read at face value.

    Everything about the package is grouped by flavour. A build's name is
    only checked for the one thing it is used for: identifying that build
    uniquely.
    """
    by_leg = defaultdict(list)
    by_flavour = defaultdict(list)
    by_flavour_type = defaultdict(list)
    by_flavour_suite = defaultdict(list)
    by_package_version = defaultdict(list)
    flavours_by_package = defaultdict(set)

    for entry in builds:
        if not isinstance(entry, dict):
            continue
        flavour = entry.get("flavour")
        delivery_type = entry.get("type")
        suite = entry.get("suite")
        if not isinstance(flavour, str):
            continue

        by_flavour[flavour].append(entry)
        by_flavour_type[(flavour, delivery_type)].append(entry)
        by_flavour_suite[(flavour, suite)].append(entry)
        by_leg[(delivery_type, entry.get("name"))].append(entry)

        for field in ("srcpkg", "binpkg"):
            if isinstance(entry.get(field), str) and entry[field]:
                flavours_by_package[(field, entry[field])].add(flavour)

        if isinstance(entry.get("srcpkg"), str) and isinstance(
            entry.get("debian_revision"), str
        ):
            by_package_version[(entry["srcpkg"], entry["debian_revision"])].append(entry)

    # A name identifies one build: it is the Actions job name and what a
    # workflow dispatch asks for. It only has to be unique within a delivery
    # type, because a run only ever resolves one type, and that lets a Daily and
    # its Release share a name. Two entries sharing both would give a run two
    # identically named jobs and make the dispatch filter ambiguous.
    for (delivery_type, name), entries in sorted(
        by_leg.items(), key=lambda item: str(item[0])
    ):
        if len(entries) > 1:
            suites = ", ".join(sorted(str(e.get("suite")) for e in entries))
            errors.append(
                f"name {name} is used by {len(entries)} {delivery_type} entries "
                f"(suites {suites}); a name identifies exactly one build"
            )

    for flavour, entries in sorted(by_flavour.items()):
        for field in FLAVOUR_IDENTITY_FIELDS:
            values = {json.dumps(entry.get(field), sort_keys=True) for entry in entries}
            if len(values) > 1:
                errors.append(
                    f"flavour {flavour} must use one {field} across all its "
                    "entries (got " + ", ".join(sorted(values)) + ")"
                )
        # A Release must be preceded by the Daily that tests it, but the
        # converse does not hold: a flavour tracking a moving upstream has
        # nothing immutable to pin, so it is built daily and never promoted.
        types = {entry.get("type") for entry in entries}
        if "Release" in types and "Daily" not in types:
            errors.append(
                f"flavour {flavour} has a Release entry but no Daily entry; "
                "a release must be preceded by the daily build that tests it"
            )

    for (flavour, suite), entries in sorted(
        by_flavour_suite.items(), key=lambda item: str(item[0])
    ):
        for field in SUITE_IDENTITY_FIELDS:
            values = {json.dumps(entry.get(field), sort_keys=True) for entry in entries}
            if len(values) > 1:
                errors.append(
                    f"flavour {flavour} must use one {field} across its "
                    f"{suite} entries (got " + ", ".join(sorted(values)) + ")"
                )

    for (flavour, delivery_type), entries in sorted(
        by_flavour_type.items(), key=lambda item: str(item[0])
    ):
        for field in REF_FIELDS:
            values = {entry.get(field) for entry in entries}
            if len(values) > 1:
                rendered = ", ".join(sorted(str(v) for v in values))
                errors.append(
                    f"flavour {flavour} must build one {field} across its "
                    f"{delivery_type} entries (got {rendered})"
                )

    # Two flavours sharing a package name would overwrite each other in the
    # archive; the whole point of a second flavour is a second package.
    for (field, package), flavours in sorted(flavours_by_package.items()):
        if len(flavours) > 1:
            errors.append(
                f"{field} {package} is shared by flavours " + ", ".join(sorted(flavours))
            )

    for (srcpkg, revision), entries in sorted(
        by_package_version.items(), key=lambda item: str(item[0])
    ):
        if len(entries) > 1:
            suites = ", ".join(sorted(str(entry.get("suite")) for entry in entries))
            errors.append(
                f"srcpkg {srcpkg} is built at debian_revision {revision} for "
                f"suites {suites}; each entry needs a revision of its own"
            )

    # A suite's Daily and Release differ only by the Daily's trailing ~, so the
    # Daily reliably sorts below the Release that supersedes it.
    for flavour, entries in sorted(by_flavour.items()):
        revisions = {
            (entry.get("type"), entry.get("suite")): entry.get("debian_revision")
            for entry in entries
        }
        for (delivery_type, suite), revision in sorted(
            revisions.items(), key=lambda item: str(item[0])
        ):
            if delivery_type != "Daily" or not isinstance(revision, str):
                continue
            release = revisions.get(("Release", suite))
            if isinstance(release, str) and revision != release + "~":
                errors.append(
                    f"flavour {flavour} suite {suite}: Daily "
                    f'debian_revision "{revision}" must be the Release revision '
                    f'"{release}" with a trailing ~'
                )


def validate(builds):
    """Return every problem found in the matrix, as a list of messages."""
    errors = []
    for index, entry in enumerate(builds):
        if not isinstance(entry, dict):
            errors.append(f"{describe(entry, index)}: delivery entries must be mappings")
            continue
        label = describe(entry, index)
        check_entry(entry, lambda message, label=label: errors.append(f"{label}: {message}"))
    check_consistency(builds, errors)
    return errors


def load_matrix(path):
    """Read, parse, and validate the matrix, returning its builds."""
    try:
        with open(path, encoding="utf-8") as handle:
            document = yaml.safe_load(handle)
    except FileNotFoundError:
        sys.exit(f"ERROR: Matrix file not found: {path}")
    except OSError as error:
        sys.exit(f"ERROR: Cannot read {path}: {error}")
    except yaml.YAMLError as error:
        sys.exit(f"ERROR: Invalid YAML in {path}: {error}")

    if not isinstance(document, dict):
        sys.exit(f"ERROR: {path}: matrix root must be a mapping with a builds key")

    # builds is the whole schema. Anything else at the root is a leftover from
    # an older matrix (suite_suffix_mapping, say) that would otherwise sit
    # there looking authoritative while nothing read it.
    unknown_root = sorted(set(document) - {"builds"})
    if unknown_root:
        sys.exit(
            f"ERROR: {path}: unknown top-level key(s) {', '.join(unknown_root)}; "
            "builds is the only one"
        )

    builds = document.get("builds")
    if not isinstance(builds, list):
        sys.exit(f"ERROR: {path}: builds must be a list")
    if not builds:
        sys.exit(f"ERROR: {path}: builds must contain at least one entry")

    errors = validate(builds)
    if errors:
        sys.exit(
            f"ERROR: Invalid kernel delivery matrix in {path}:\n"
            + "\n".join(f"  - {error}" for error in errors)
        )

    # Derived, never written: family follows from suite, so the matrix cannot
    # state one that disagrees with the suite it is built for. Attached after
    # validation, which rejects family as an unknown field on an entry.
    for entry in builds:
        entry["family"] = family_for(entry["suite"])

    return builds


def parse_filter(value):
    """Split a comma-separated filter into names, or None when unset."""
    if not value:
        return None
    return [name.strip() for name in value.split(",") if name.strip()]


def select(builds, delivery_type, filters):
    """Return the entries matching the requested filters, in matrix order.

    filters maps a field name to the list of values allowed for it, or to
    None when that filter was not given.
    """
    return [
        entry
        for entry in builds
        if entry["type"] == delivery_type
        and all(
            wanted is None or entry[field] in wanted
            for field, wanted in filters.items()
        )
    ]


def unmatched_filters(builds, delivery_type, filters):
    """Names asked for that no entry of this delivery type offers.

    family is exempt: it routes a selection to a build path rather than naming
    something in the matrix, argparse already restricts it to a real family,
    and a type having no builds on one path is an ordinary state of the matrix
    rather than a mistake in the request.
    """
    missing = []
    for field, wanted in filters.items():
        if wanted is None or field == "family":
            continue
        available = {
            entry[field] for entry in builds if entry["type"] == delivery_type
        }
        for name in wanted:
            if name not in available:
                missing.append(
                    f"no {delivery_type} entry has {field} {name} "
                    f"(available: {', '.join(sorted(available))})"
                )
    return missing


def describe_selection(delivery_type, filters):
    """Render the active filters for an error message."""
    parts = [f"type={delivery_type}"]
    parts += [
        f"{field}={','.join(wanted)}"
        for field, wanted in filters.items()
        if wanted is not None
    ]
    return " ".join(parts)


def for_workflow(entry):
    """Shape one entry the way build-kernel-deb.yml's inputs expect it."""
    return {
        **entry,
        "kernel_config": ",".join(entry["kernel_config"]),
        "dkms": ",".join(entry["dkms"]),
    }


def main():
    parser = argparse.ArgumentParser(
        description="Validate and select entries from the kernel delivery matrix.",
        epilog="See the module docstring in this file for full documentation.",
    )
    parser.add_argument(
        "--type", required=True, choices=DELIVERY_TYPES, help="delivery type to select"
    )
    parser.add_argument(
        "--build",
        default="",
        help="select only these builds by name, comma-separated",
    )
    parser.add_argument(
        "--flavour", default="", help="select only these flavours, comma-separated"
    )
    parser.add_argument(
        "--suite", default="", help="select only these suites, comma-separated"
    )
    parser.add_argument(
        "--family",
        default="",
        choices=("",) + FAMILIES,
        help="select only the builds taking this build path",
    )
    parser.add_argument(
        "--allow-empty",
        action="store_true",
        help="print [] instead of failing when the filters select nothing",
    )
    parser.add_argument(
        "--field",
        default="",
        help="print just this field of the single selected entry",
    )
    parser.add_argument(
        "--matrix-file", default=DEFAULT_MATRIX_FILE, help="path to the matrix YAML"
    )
    args = parser.parse_args()

    builds = load_matrix(args.matrix_file)
    filters = {
        "name": parse_filter(args.build),
        "flavour": parse_filter(args.flavour),
        "suite": parse_filter(args.suite),
        "family": parse_filter(args.family),
    }
    what = describe_selection(args.type, filters)

    # Report a name that matches nothing before reporting an empty selection:
    # "no Daily entry has name qcom-next" says what to fix, where
    # "no entries found" leaves the reader to work out which filter was wrong.
    unmatched = unmatched_filters(builds, args.type, filters)
    if unmatched:
        sys.exit(
            f"ERROR: Nothing to build for {what}:\n"
            + "\n".join(f"  - {problem}" for problem in unmatched)
        )

    selected = select(builds, args.type, filters)
    if not selected:
        # A caller splitting one dispatch across both build paths asks each
        # family for the same selection, and one of them legitimately has
        # nothing to build. Every name in the request still had to match
        # something above, so this is an empty intersection, not a typo.
        if args.allow_empty and not args.field:
            print("[]")
            return
        sys.exit(f"ERROR: No matrix entries found for {what}")

    if not args.field:
        print(json.dumps([for_workflow(entry) for entry in selected], separators=(",", ":")))
        return

    if len(selected) > 1:
        sys.exit(
            f"ERROR: --field {args.field} needs exactly one entry, but {what} "
            f"selects {len(selected)}; narrow it with --build"
        )

    entry = for_workflow(selected[0])
    if args.field not in entry:
        sys.exit(
            f"ERROR: {what} has no field {args.field}; "
            "available: " + ", ".join(sorted(entry))
        )
    print(entry[args.field])


if __name__ == "__main__":
    main()
