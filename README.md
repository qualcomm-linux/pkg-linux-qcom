# pkg-linux-qcom

CI orchestration for ARM64 Linux kernel package variants. The configured
variants build from
[`qualcomm-linux/kernel`](https://github.com/qualcomm-linux/kernel).

This branch owns both halves of the chain: the build matrix and GitHub Actions
workflows, and the Debian packaging tree and local packaging tools. Every build
takes its packaging and its CI scripts from the same commit.

## Overview

The CI model is matrix-driven. This single repository can deliver multiple
kernel variants, each with independent source/package identity, kernel source
and ref strategy, configuration fragments, Debian revision, target suites, and
release destination.

Every entry in the matrix is one isolated build leg producing one package. A
kernel flavour owns as many entries as it has suites and delivery types.

### Configured variants

| Variant | Source package | Image metapackage | Daily suites | Release suites | Notes |
|---------|----------------|-------------------|--------------|----------------|-------|
| `qcom-next` | `linux-qcom-next` | `linux-image-qcom-next` | trixie, forky, resolute | trixie, forky | Standard kernel |
| `qcom-next-debug` | `linux-qcom-next-debug` | `linux-image-qcom-next-debug` | trixie, forky | trixie, forky | Adds `arch/arm64/configs/qcom_debug.config` and `kernel/configs/debug.config` from the kernel source, via `intree:` entries |
| `qcom-arduino` | `linux-qcom-arduino` | `linux-image-qcom-arduino` | trixie, forky | none | Arduino hardware-enablement topic branch (`early/hwe/arduino` of `kernel-topics`) |
| `mainline` | `linux-mainline` | `linux-image-mainline` | trixie, forky | none | Tip of Linus's tree, tracked for early warning of upstream breakage. No DKMS modules |
| `next` | `linux-next` | `linux-image-next` | trixie, forky | none | Newest `next-YYYYMMDD` tag of linux-next. No DKMS modules |

`derive-localversion.sh` folds the *flavour* into LOCALVERSION, so each
produces a distinct kernel release (`+qcom-next-<date>-g<sha>`,
`+qcom-next-debug-<date>-g<sha>`, and so on) and therefore a distinct versioned
image package that can be installed alongside the others. The flavour is what
the kernel is; a build's `name` is only what CI calls it. See
[docs/version.md](docs/version.md) for how the version strings are composed.

The last three track a moving upstream — a branch tip, or a tag cut every
night — and so have no `Release` entries: a release must name an immutable ref
to promote. They are built and published daily and never promoted to `qli`.

`ci/build-matrix.yaml` is the source of truth; this table is a summary.

Two entry points use the same reusable build pipeline:

- **Daily** uses the matrix-selected latest-tag or branch-tip strategy and
  builds every configured Daily suite.
- **Release** uses a pinned matrix ref and promotes successful Debian packages
  to the selected production Debusine workspace.

One entry in `builds` is one generated package: a single `name`, a single
`type`, and a single `suite`. The `name` labels that one build and nothing
else — it is the Actions job name and what a manual dispatch asks for. Nothing
is expanded or derived at resolve time, so what an entry says is what gets
built:

```yaml
builds:
  - name: qcom-next-trixie
    type: Daily
    suite: trixie
    flavour: qcom-next
    git_clone: https://github.com/qualcomm-linux/kernel
    branch_or_tag: qcom-next
    ref_strategy: latest_tag
    tag_pattern: 'qcom-next-*'
    srcpkg: linux-qcom-next
    binpkg: linux-image-qcom-next
    kernel_config: []
    dkms:
      - kgsl
      - camx
      - iris-vpu
      - audioreach
    debian_revision: '0qli1~bpo13+1~'

  - name: qcom-next-trixie
    type: Release
    suite: trixie
    flavour: qcom-next
    git_clone: https://github.com/qualcomm-linux/kernel
    branch_or_tag: <pinned-qcom-next-tag>
    ref_strategy: pinned_ref
    srcpkg: linux-qcom-next
    binpkg: linux-image-qcom-next
    kernel_config: []
    dkms:
      - kgsl
      - camx
      - iris-vpu
      - audioreach
    debian_revision: '0qli1~bpo13+1'
    target_workspace: qli
```

Entries are written out in full rather than sharing YAML anchors, so each one
can be read, grepped, and changed on its own. `resolve-matrix.py` enforces the
consistency that duplication would otherwise put at risk — see
[Matrix Model](#matrix-model).

Each entry states its `debian_revision` outright. The configured values are:

| Suite | Daily | Release |
| --- | --- | --- |
| Trixie | `0qli1~bpo13+1~` | `0qli1~bpo13+1` |
| Forky | `0qli1~` | `0qli1` |
| Resolute | `0qli1~26.04.1~` | (not a configured Release suite) |

`~` always sorts below the same prefix without it in Debian version
ordering, so a suite's Daily always sorts below its Release; `resolve-matrix.py`
requires a Daily revision to be exactly its Release revision plus a trailing
`~`. Ordering across *different* suites depends entirely on the configured
revisions: with the values above, Resolute < Trixie < Forky for the same
delivery type, matching a Debian-backports-then-unstable promotion chain.
This is a deliberate ordering policy, not an automatic guarantee — adding a
suite means choosing a revision that sorts where that suite belongs relative to
the others. One nuance to be aware of: because Forky's revision carries no
suite component, its Daily revision ends immediately after the trailing `~`, so
Trixie Daily does not sort below Forky Daily even though Trixie Release sorts
below Forky Release. This does not affect the supported Release-to-Release
upgrade path.

`ci/build-matrix.yaml` is the authoritative configuration. Adding a kernel
variant is a matrix change, not a workflow redesign.

## Workflows

| Workflow | Purpose | Trigger |
| --- | --- | --- |
| `daily.yml` | Resolves and runs the Daily matrix. The manual build entry point. | Scheduled daily at `23:00 UTC`, or manual dispatch. |
| `release.yml` | Resolves and runs the Release matrix. | Manual dispatch only. |
| `build-kernel-debian.yml` | Builds one Debian-suite entry in Debusine and publishes it to S3. | Called by Daily and PR build. |
| `build-kernel-ubuntu.yml` | Builds one Ubuntu-suite entry on the Docker path and publishes it to S3. | Called by Daily and PR build. |
| `release-kernel-debian.yml` | Builds one Debian-suite entry in Debusine and promotes it to the release workspace. | Called by Release. |

The three build workflows share their steps through two composite actions
rather than through a common orchestrator workflow:

| Action | Used by |
| --- | --- |
| `.github/actions/prepare-kernel-source` | All three, as the `prepare` job. |
| `.github/actions/debusine-build` | The two Debian workflows, as the `build` job. |

Which of them a build leg calls is decided by the caller, from the entry's
suite: `resolve-matrix.py --family debian|ubuntu` splits the selection, and
each family's entries call only the workflow that builds them. Nothing inside a
build workflow is conditional on the suite or on whether the run releases, so a
run starts exactly the jobs it needs and shows no skipped job for a path it did
not take.

### Daily

Daily is the recurring build and artifact-publication path.

- The scheduled run resolves the full `Daily` matrix.
- A manual run says which entries to build in one **Builds** field:
  - `all`, the default, builds every configured variant and suite.
  - A comma-separated list of build names builds those entries, e.g.
    `qcom-next-trixie,qcom-next-debug-forky`. A name matching no `Daily` entry
    fails the run rather than narrowing it, and both families are selected from
    one list, so a mixed list starts Debian and Ubuntu legs from one dispatch.
- `latest_tag` resolves the newest matching dated tag; `branch_tip` resolves
  the configured branch directly.
- Debian suites build in Debusine, then their `.deb` outputs are downloaded and
  uploaded to the configured S3 bucket.
- `resolute` stays on the Docker-based Ubuntu path and uploads its package
  outputs to the existing temporary-package S3 location.

### Release

Release is the controlled promotion path.

- It is manual only, and says which entries to release in one **Builds** field,
  the same way Daily does:
  - `all`, the default, promotes every configured `Release` entry.
  - A comma-separated list of build names promotes those entries when a
    targeted action is required, e.g. `qcom-next-trixie,qcom-next-forky`.
- It uses the pinned `branch_or_tag` from the selected `Release` matrix row; it
  never resolves a newest tag.
- Debian source and binary artifacts are built in per-flavour, per-suite
  Debusine CI workspaces.
- Successful builds are promoted with Debusine's `package-publish` workflow to
  the `qli` workspace, where they are available through the production Debusine
  APT repository.
- The Release job runs in the **Production** GitHub environment. This provides
  the release credential and enforces the required approval gate before
  promotion to `qli`.

A `daily.yml` dispatch is build-only: it publishes to the daily S3 path and has
no promotion path to offer. Release promotion is initiated exclusively by
`release.yml`, which owns the target workspace and production release controls,
and is the only caller of `release-kernel-debian.yml`.

Only the Debian family has a release path at all, because promotion runs
through Debusine. `resolve-matrix.py` rejects a `Release` entry for any other
suite rather than letting it build and then silently not promote.

## Matrix Model

`ci/build-matrix.yaml` is a mapping with exactly one top-level key, `builds`.
One entry in it is one generated package, so there is no
expansion step: `ci/scripts/resolve-matrix.py` validates the whole document,
selects the entries matching the requested type, variant, and suite, and hands
them to the workflow matrix as they stand. Each entry carries:

| Field | Purpose |
| --- | --- |
| `name` | The name of this one build, and nothing else: its Actions job name, and what a manual dispatch asks for. Unique within a delivery type, so a Daily and its Release may share a name. Never reaches a package name, a version, or a published path. Lowercase letters, digits, and internal hyphens only, and not `all`, which a dispatch reads as every entry. |
| `type` | `Daily` or `Release`. |
| `suite` | The one suite this entry builds for. |
| `flavour` | The kernel's own identity, and the only matrix field that reaches the built kernel. `derive-localversion.sh` makes it the LOCALVERSION suffix, so two flavours built from one ref get distinct kernel releases and their `linux-image` packages coexist. All entries sharing a flavour build the same package for different suites. |
| `git_clone` | Kernel source repository. |
| `branch_or_tag` | Source branch or pinned tag, according to `ref_strategy`. |
| `ref_strategy` | `latest_tag`, `branch_tip`, or `pinned_ref`. |
| `tag_pattern` | Required only for `latest_tag`; matching tags must end in `-YYYYMMDD`, which determines newest-first ordering. |
| `srcpkg` | Debian source package name. |
| `binpkg` | Kernel image metapackage name. |
| `kernel_config` | Extra fragments applied on top of `debian/config-available/`, all of which is applied to every build, one per list element. A bare name selects `debian/config-available/<name>.config`; an `intree:` entry names a fragment shipped by the kernel source, as a path relative to the kernel source root (e.g. `intree:arch/arm64/configs/qcom_debug.config`), so it stays versioned with the kernel it targets. Empty for variants that need nothing beyond `config-available/`; today it carries only `intree:` fragments. `resolve-matrix.py` joins it into the comma-separated `kernel-config` workflow input. |
| `dkms` | Out-of-tree DKMS modules built and bundled into the image package, one per list element, each named without the `-dkms` suffix (e.g. `kgsl`). Each needs a `<name>-dkms` package in the suite being built for, so this varies between suites. An empty list bundles nothing. A listed module is a presence contract: a build fails rather than shipping an image without it. `resolve-matrix.py` joins it into the comma-separated `dkms` workflow input, which reaches `prepare-source.sh --dkms`; see [debian/README.md](debian/README.md) for what the packaging does with it. |
| `debian_revision` | The Debian revision this package is built at, stated outright. Daily revisions end in `~`; Release revisions do not. |
| `localversion`, `kver_extra` | Optional version overrides forwarded to packaging. |
| `debusine_parent_workspace` | Optional parent workspace override for the variant's CI child workspaces. |
| `target_workspace` | Debusine destination for Release entries only. |

`resolve-matrix.py` rejects the matrix — before any build job starts — where an
entry has an unknown field or a missing required one, a malformed variant or
suite identifier, a `ref_strategy` its `type` does not allow (`Daily` must
track something moving, `Release` must be pinned), a `tag_pattern` without
`latest_tag`, a `target_workspace` on a `Daily` entry or none on a `Release`
one, a `kernel_config` fragment that escapes the kernel source root or collides
with another fragment's filename, a `dkms` entry that is not a package name
stem or repeats, or a `debian_revision` that is not a valid Debian revision or
carries the wrong trailing `~` for its `type`.

Because entries are written out in full, the resolver also checks the
invariants that span them, which is what makes the duplication safe to read at
face value:

- No two entries of one `type` share a `name` — a name identifies exactly one
  build, so a run cannot produce two jobs with one name and a dispatch cannot
  be ambiguous.
- A flavour's entries agree on `srcpkg`, `binpkg` and `kernel_config`; those
  decide what the package *is*, and the entries differ only in where it goes.
- A flavour's entries for one suite agree on `dkms`. The module set depends on
  which `<name>-dkms` packages the target archive carries, so it varies between
  suites — but a suite's Daily and Release must match, or the Daily is not
  testing the module set the Release will ship.
- A flavour's entries of one `type` agree on `git_clone`, `branch_or_tag`,
  `ref_strategy` and `tag_pattern`, so a forgotten suite cannot quietly ship a
  different kernel from its siblings after a release ref bump.
- A flavour with a `Release` entry also has a `Daily` one, so nothing is
  promoted that the daily build has not tested. The converse is allowed: a
  flavour tracking a moving upstream is built daily and never released.
- No `srcpkg` or `binpkg` is shared between flavours, and no two entries build
  the same `srcpkg` at the same `debian_revision`.
- Where a suite has both, its `Daily` revision is its `Release` revision plus a
  trailing `~`.

The build workflows pass their entry's own `debian_revision` through. A caller
with no entry in hand can leave the `debian-revision` input empty, and the
`prepare-kernel-source` action looks up the `Daily` entry for the build name and
suite it was given (`resolve-matrix.py --field debian_revision`) and builds at
the revision the daily build would have used.

Each entry has a distinct prepared-source artifact, Debusine child workspace,
and S3 path keyed by `flavour + suite`. This prevents two flavours that both
build, for example, `trixie` from consuming or publishing each other's inputs
or outputs. They key on `flavour`, not on the build's `name`, so renaming a
build never moves a published artifact.

Daily S3 outputs use these layouts, where `<run>` is
`<github.run_id>-<github.run_attempt>`:

```text
<org>/pkg/debusine/<repo>/<flavour>/<suite>/<run>/
<org>/pkg/temp/<repo>/<flavour>/<suite>/<run>/
```

The first layout is for Debian/Debusine builds; the second is for Ubuntu Docker
builds. Consumers must select the intended flavour and suite.

Supporting scripts keep workflow YAML small and testable:

| Script | Responsibility |
| --- | --- |
| `ci/scripts/resolve-matrix.py` | Validates the delivery matrix and selects the entries to build. Needs PyYAML (`python3-yaml`). |
| `ci/scripts/resolve-kernel-ref.sh` | Resolves a matrix-selected dated tag or validates a direct ref. |
| `ci/scripts/derive-localversion.sh` | Derives the version fields from the flavour, resolved kernel ref and HEAD, printing `LOCALVERSION=`, `SNAPSHOT=` and `GITSHA=` lines. `SNAPSHOT` is the dated component of the Debian version: the tag's date, or the HEAD commit date for a branch-tip build. Scheme and rationale: [docs/version.md](docs/version.md). |

## Architecture

This repository contains two separate parts:
- the CI generator (`.github/workflows/`, `ci/`) that decides *what* to build,
- the Debian packaging (`debian/`, `prepare-source.sh`, `build-kernel.sh`) that
  decides *how* it is built.

This document covers the CI generator. For the packaging internals: `debian/rules`
targets, the config fragment merge pipeline, DKMS module bundling and the produced
package layout see [debian/README.md](debian/README.md).

Both branches below are taken in the caller, when the matrix is resolved: the
family from the entry's suite, the tail from which workflow is running. By the
time a build workflow starts, there is nothing left to decide.

```mermaid
flowchart LR
    IN["Matrix entries"] --> R{"resolve-matrix.py\n--family"}

    R -->|"debian: trixie · forky"| DT{"Which caller"}
    R -->|"ubuntu: resolute"| UBU["build-kernel-ubuntu.yml\nbuild-kernel.sh in Docker\nBuild binary packages"]

    DT -->|"daily.yml · pr-build.yml"| DEB["build-kernel-debian.yml\nGenerate source package\nSubmit with lib/build\nDebusine builds binaries"]
    DT -->|"release.yml"| REL["release-kernel-debian.yml\nSame build, release tail"]

    DEB --> S3["Download .deb files\nPublish to S3"]
    REL --> QLI["Promote source and binaries\nto qli"]
    UBU --> US3["Publish .deb files to S3"]
```

## For CI Maintainers

### Pipeline overview

```mermaid
flowchart TD
    subgraph triggers[Triggers]
        A1["daily.yml\nScheduled full matrix"]
        A2["daily.yml\nManual: all or named builds"]
        A5["pr-build.yml\nFull Daily matrix on every PR"]
        A3["release.yml\nManual: all or named builds"]
    end

    subgraph matrix[Matrix entry points]
        B1["configure-matrix\nDaily entries, split by family"]
        B2["build-debian legs\nqcom-next · qcom-next-debug · qcom-arduino\nmainline · next / trixie · forky"]
        B5["build-ubuntu legs\nqcom-next / resolute"]
        B3["configure-matrix\nRelease entries, Debian by construction"]
        B4["build legs\nqcom-next · qcom-next-debug / trixie · forky"]
    end

    subgraph build[One build workflow per leg]
        C2["prepare\nprepare-kernel-source action\nClone ref, run prepare-source.sh\nUpload kernel-srcpkg-flavour-suite"]
        C3["build\ndebusine-build action"]
        C4["build\nbuild-kernel.sh in Docker"]
        C5["publish\nDownload .deb files, upload to S3"]
        C6["release\nPromote to target workspace"]
    end

    subgraph outputs[Outputs]
        D1["Daily S3 artifacts"]
        D2["Release qli APT repository"]
    end

    A1 --> B1
    A2 --> B1
    A5 --> B1
    A3 --> B3
    B1 --> B2 & B5
    B3 --> B4
    B2 --> C2
    B5 --> C2
    B4 --> C2
    C2 --> C3 & C4
    C3 --> C5 & C6
    C4 --> D1
    C5 --> D1
    C6 --> D2
```

Every leg runs every job drawn under it. `build-debian` and `build-ubuntu` legs
reach different build workflows, and `publish` and `release` belong to
different ones, so no leg starts a job it will skip.

### Prepare stage

```mermaid
flowchart LR
    K["Matrix-selected kernel repository\nDaily: latest tag or branch tip\nRelease: pinned ref"] --> PS
    M["pkg-linux-qcom\ndebian/ and ci/ from this commit"] --> PS

    PS["prepare-source.sh\n\nInject debian/\nApply all config-available fragments plus any extras\nGenerate control, changelog, localversion, pkgversion"] --> TAR
    TAR["tar czf kernel-srcpkg-variant-suite.tar.gz\nPreserves execute permissions"] --> ART
    ART["GitHub Actions artifact\nOne prepared source tree per variant + suite"]
```

> **Why `tar.gz`?** `actions/upload-artifact` uses zip internally, which strips
> Unix execute bits. Kernel build scripts require those permissions. The tar
> archive preserves them between the prepare and build jobs.

### Debian Daily path

```mermaid
flowchart LR
    ART["kernel-srcpkg-variant-suite\nartifact"] --> GSP

    subgraph source[GitHub build job: debusine-pkg-builder container]
        GSP["generate-source-package\nDEBUSINE_ASSEMBLE_ORIG=true\n\nCreate .orig.tar.gz\nRun dpkg-buildpackage -S\nProduce .dsc"] --> SUBMIT
        SUBMIT["lib/build\nCreate CI child workspace\nSubmit source package to Debusine"]
    end

    SUBMIT --> DEB["Debusine\nBuild binary packages"]
    DEB --> WS["Unique variant + suite workspace"]

    subgraph publish[Daily publish job]
        WS --> APT["generate-apt-config\nchdist isolated APT environment\nDownload .deb files"]
        APT --> S3["S3\nDaily package artifacts"]
    end
```

### Debian Release path

```mermaid
flowchart LR
    ART["kernel-srcpkg-variant-suite\nartifact"] --> GSP["generate-source-package\nProduce .dsc"]
    GSP --> SUBMIT["lib/build\nSubmit source package to a unique\nDebusine CI child workspace"]
    SUBMIT --> DEB["Debusine\nBuild binary packages"]
    DEB --> WS["CI workspace\nsource and binary artifacts"]

    subgraph release[Release job: Production GitHub environment]
        WS --> PROMOTE["lib/release\nStart package-publish"]
        PROMOTE --> QLI["qli\nProduction Debusine APT repository"]
    end
```

### Ubuntu path

```mermaid
flowchart LR
    ART["kernel-srcpkg-variant-suite\nartifact"] --> EXT

    subgraph build[Ubuntu build job]
        EXT["Extract prepared source tree\n--strip-components=1"] --> BK
        BK["build-kernel.sh\n--skip-prepare\n--local-source\n--build-mode docker\ndpkg-buildpackage -b"] --> S3
    end

    S3["S3\nDaily package artifacts"]
```

`--skip-prepare` is safe because `prepare-source.sh` has already generated the
packaging metadata and applied the config fragments before the artifact is
created.

## Packages

The matrix provides the source package and image metapackage identity. The
resolved kernel release remains the source of truth for versioned package names
and installed kernel paths.

For the current matrix, package generation produces:

| Package | Purpose |
| --- | --- |
| `linux-qcom-next_<version>.dsc` and related source files | Debian source package. |
| `linux-image-<kernelrelease>_<version>_arm64.deb` | Versioned kernel image, modules, DTBs, and boot assets. |
| `linux-image-qcom-next_<version>_arm64.deb` | Image metapackage that tracks the newest kernel image. |
| `linux-headers-<kernelrelease>_<version>_arm64.deb` | Versioned headers for DKMS and out-of-tree modules. |
| `linux-headers-qcom-next_<version>_arm64.deb` | Headers metapackage. |
| `linux-image-<kernelrelease>-dbg_<version>_arm64.deb` | Kernel and module debug symbols. |

`-rcN` remains in `uname -r`, module paths, boot assets, and versioned package
names. Only the Debian version field converts it to `~rcN`, so a release
candidate correctly sorts before the corresponding final kernel release.

Every build names both its snapshot and the commit it was cut from:

| | Format | Example |
| --- | --- | --- |
| Kernel release (`uname -r`) | `<base>+<variant>-<date>[.<respin>]-g<sha>` | `7.2.0-rc7+qcom-next-20260826.1-g011a82096bee` |
| Debian version | `<base>+git<date>[.<respin>]~g<sha>-<revision>` | `7.2.0~rc7+git20260826.1~g011a82096bee-0qli1~bpo13+1` |

The two strings spell the same fields differently because they are compared by
different rules — `+` and `~` are both load-bearing, not stylistic. See
[docs/version.md](docs/version.md) before changing either.

`KVER_EXTRA` is supported for explicit suffixes such as `-ci42` or `-local`.
The packaging rules verify that the declared versioned image package matches the
resolved kernel release and fail instead of creating inconsistent metadata.

For an APT repository installation, install the image metapackage:

```bash
sudo apt update
sudo apt install linux-image-qcom-next
```

When installing downloaded artifacts directly, install the versioned image and
its metapackage together. Add the headers packages when DKMS or other
out-of-tree module builds are required.

## Manual Builds

Use **Actions** → **daily** → **Run workflow** for a one-off build, and
**Actions** → **release** to promote. Both are dispatched the same way: one
**Builds** field naming what to run.

| Input | Default | Purpose |
| --- | --- | --- |
| `builds` | `all` | `all` runs every entry of that workflow's delivery type. Otherwise a comma-separated list of build `name` values from `ci/build-matrix.yaml`, e.g. `qcom-next-trixie,qcom-next-debug-forky`. |

Everything else about a build — its suite, flavour, kernel repository and ref,
package names, config fragments, DKMS modules and Debian revision — comes from
the entry, so there is nothing to retype and nothing to get wrong. Build names
are free-text matrix values rather than a static dropdown, so adding a matrix
entry never requires editing the workflow UI, and a name that matches no entry
of the delivery type fails the run with the list of names that do. `daily`
routes each selected entry to the workflow that builds its family, so one
dispatch can name Debian and Ubuntu builds together.

`daily` carries three further inputs, which the matrix deliberately says
nothing about because they belong to a one-off validation run rather than to a
delivery target. They apply to every selected build, and a scheduled run leaves
them at their defaults:

| Input | Default | Purpose |
| --- | --- | --- |
| `debug-build` | `false` | Advanced debug configuration toggle. For a lasting debug kernel, use the `qcom-next-debug` flavour instead. |
| `qcom-next-pr` | Empty | Advanced Qualcomm-only override: `qcom-next` PR numbers to merge before building. |
| `kernel-topics-pr` | Empty | Advanced Qualcomm-only override: `kernel-topics` PR numbers to apply as patches. |

A `daily` dispatch is an artifact build and publishes to the daily S3 path;
Release promotion is performed only through `release.yml`. The build workflows
themselves (`build-kernel-debian.yml`, `build-kernel-ubuntu.yml`,
`release-kernel-debian.yml`) are `workflow_call` only and cannot be dispatched:
one run of each is one matrix entry, and a reusable workflow cannot fan itself
out over a list.

## Configuration

### Repository and organization variables

| Variable | Purpose |
| --- | --- |
| `ARTIFACT_S3_BUCKET` | S3 bucket for Daily Debian artifacts and Ubuntu build artifacts. |
| `DEBUSINE_HOST` | Production Debusine host. |
| `DEBUSINE_SCOPE` | Debusine scope. |
| `DEBUSINE_PARENT_WORKSPACE` | Parent workspace used to create per-run CI child workspaces. |

### Secrets

| Secret | Scope | Purpose |
| --- | --- | --- |
| `DEBUSINE_USER` | Repository | User for Debusine archive and signing-key access. |
| `DEBUSINE_TOKEN` | Repository | Token for Debusine build and artifact operations. |
| `DEBUSINE_RELEASE_TOKEN` | Production environment | Token used only to promote Release artifacts to `qli`. |

The Debian build and Release jobs select the **Production** GitHub environment.
This makes environment-scoped release credentials available to the promotion job
and keeps production approval controls in the workflow path.

## Maintaining the Matrix

To add a kernel variant:

1. Add one entry to `builds` per package the variant should produce: one per
   Daily suite and one per Release suite, each spelling out all of its own
   fields, and each with a `name` unique within its delivery type. Do not rely
   on another variant's values.
2. Give them all the same `flavour`, distinct from every other flavour's — it
   becomes the LOCALVERSION suffix, so this is what lets the new kernel install
   alongside the existing ones. Keep `srcpkg`, `binpkg` and `kernel_config`
   identical across every entry for the flavour, and the ref fields identical
   across its entries of one `type`. `resolve-matrix.py` rejects the matrix if
   they drift apart.
3. Use `latest_tag` with a dated tag glob or `branch_tip` for Daily. Use
   `pinned_ref` for Release, and update that ref through a reviewed PR.
4. Give the variant distinct `srcpkg` and `binpkg` values. Set
   `target_workspace` on each Release entry.
5. Give each entry a `debian_revision`: the Daily one is the Release one for
   the same suite plus a trailing `~`.
6. Confirm suite-family routing: Debian suites use Debusine; Ubuntu suites use
   the Docker path.
7. Run a filtered Daily validation for the new variant, then its full Daily and
   Release flows.

To add a new suite (for an existing or new variant):

1. Add one entry per delivery type the suite should get, copying the variant's
   existing entry for that type and changing `suite` and `debian_revision`.
2. Choose the revision so the suite sorts where it belongs relative to the
   others for the same delivery type (see the ordering discussion in
   [Overview](#overview)), and so it does not collide with another entry
   building the same `srcpkg`.

No workflow dispatch choices need to be updated: the Daily and Release
dispatches take build names as free text, so a new entry is dispatchable by
name, and is picked up by `all`, as soon as it is merged.

Run `ci/scripts/resolve-matrix.py --type Daily` and `--type Release` locally to
validate a matrix change before pushing it; both validate the whole document,
so either one catches a mistake in the other's entries.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for branch, review, and DCO
requirements.

## License

pkg-linux-qcom is licensed under the BSD 3-Clause License. See
[LICENSE.txt](LICENSE.txt).
