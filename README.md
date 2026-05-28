# pkg-linux-qcom

Debian/Ubuntu kernel packaging for `qualcomm-linux/kernel` on ARM64 Qualcomm platforms.
Produces installable `.deb` packages via a dual-path CI pipeline — **Debusine** for Debian suites, **docker** for Ubuntu suites.

---

## Pipeline Overview

```mermaid
flowchart TD
    subgraph Triggers
        A1["⏰ daily.yml\n3 PM PST · cron"]
        A2["🖱 daily.yml\nManual dispatch"]
        A3["🖱 build-kernel-deb.yml\nManual dispatch"]
    end

    subgraph daily.yml
        B1["configure-matrix\nReads ci/build-matrix.json"]
        B2["build · trixie"]
        B3["build · resolute"]
    end

    subgraph build-kernel-deb.yml
        C1["resolve\nClassify suite family"]
        C2["prepare\nClone · patch · prepare-source.sh\nUpload kernel-srcpkg artifact"]
        C3["debusine-build\nDebian suites only"]
        C4["ubuntu-build\nUbuntu suites only"]
        C5["upload-artifacts\nDebian suites only"]
    end

    subgraph Outputs
        D1["S3 · linux-image · linux-headers · dbg"]
    end

    A1 --> B1
    A2 --> B1
    B1 --> B2 & B3
    B2 -->|workflow_call distro=trixie| C1
    B3 -->|workflow_call distro=resolute| C1
    A3 -->|workflow_dispatch| C1

    C1 --> C2
    C2 --> C3 & C4
    C3 --> C5
    C5 --> D1
    C4 --> D1
```

---

## Suite Routing

```mermaid
flowchart LR
    IN["distro input"] --> R{resolve job}

    R -->|trixie · sid\nunstable · bookworm| DEB["family = debian"]
    R -->|noble · questing\nresolute| UBU["family = ubuntu"]

    DEB --> DB["debusine-build\nqcom-build-utils reusable workflow\nGenerates .dsc → submits to Debusine\nDownloads .deb via chdist → S3"]
    UBU --> UB["ubuntu-build\nbuild-kernel-ubuntu.yml\nbuild-kernel.sh --skip-prepare\ndocker pkg-builder:suite → S3"]
```

---

## Workflow Files

| File | Role | Trigger |
|---|---|---|
| `daily.yml` | Daily orchestrator — reads matrix, spawns parallel builds | `schedule` · `workflow_dispatch` |
| `build-kernel-deb.yml` | Main build pipeline — 5 jobs, dual-path routing | `workflow_dispatch` · `workflow_call` |
| `build-kernel-ubuntu.yml` | Ubuntu build module — `build-kernel.sh` path | `workflow_call` only |

---

## Daily Build Matrix

**`ci/build-matrix.json`** — one entry per nightly build target:

```json
[
  { "distro": "trixie" },
  { "distro": "resolute" }
]
```

> To add a nightly target: append one entry. No workflow changes needed.

### Manual Dispatch Options (`daily.yml`)

| Input | Type | Behaviour |
|---|---|---|
| `run-full-matrix` ☑ | boolean | Runs all matrix entries — identical to scheduled daily build |
| `run-full-matrix` ☐ + `distro` | choice | Runs a single distro build |

---

## `build-kernel-deb.yml` Inputs

### `workflow_dispatch` (manual single build)

| Input | Default | Description |
|---|---|---|
| `distro` | `trixie` | Target suite |
| `latest-tag` | `true` | Use latest `qcom-next-*` tag |
| `kernel-branch` | `qcom-next` | Branch/tag when `latest-tag=false` |
| `kernel-url` | qualcomm-linux/kernel | Custom kernel repo URL |
| `pkg-linux-qcom-ref` | `qcom/debian/latest` | Packaging metadata ref |
| `localversion` | — | Override LOCALVERSION suffix |
| `kver-extra` | — | Extra suffix appended to package version |
| `debug-build` | `false` | Copies `debug.config` into `debian/config/` |
| `self-pr` | — | Apply a pkg-linux-qcom PR before building |
| `qcom-next-pr` | — | Space-separated qcom-next PR numbers to merge |
| `kernel-topics-pr` | — | Space-separated kernel-topics PR numbers to apply |

### `workflow_call` (called by `daily.yml`)

| Input | Default | Description |
|---|---|---|
| `distro` | `trixie` | Target suite |
| `latest-tag` | `true` | Always true for daily builds |
| `pkg-linux-qcom-ref` | `qcom/debian/latest` | Packaging metadata ref |

---

## Prepare Stage — Source Tree Assembly

```mermaid
flowchart LR
    K["qualcomm-linux/kernel\nlatest qcom-next-* tag"] --> PS
    M["pkg-linux-qcom\ndebian/ metadata"] --> PS

    PS["prepare-source.sh\ninside pkg-builder:DISTRO container\n\n① Inject debian/\n② Activate config fragments\n③ debian/rules prepare\n   → debian/control\n   → debian/changelog"] --> TAR

    TAR["tar czf kernel-srcpkg.tar.gz\nPreserves execute permissions\n(zip strips them)"] --> ART

    ART["GitHub Actions Artifact\nkernel-srcpkg\nShared across jobs via run_id"]
```

> **Why `tar.gz`?** `actions/upload-artifact` uses zip internally, which strips Unix execute bits.
> Kernel build scripts (e.g. `scripts/cc-version.sh`) require execute permission.
> `tar` preserves them end-to-end; `--strip-components=1` restores them on extraction.

---

## Debian Path — Debusine

```mermaid
flowchart LR
    ART["kernel-srcpkg artifact"] --> GSP

    GSP["generate-source-package\nDEBUSINE_ASSEMBLE_ORIG=true\n\n① tar czf .orig.tar.gz\n   (excludes debian/ .git/)\n② dpkg-buildpackage -S\n   → .dsc + .debian.tar.xz"] --> DEB

    DEB["Debusine\nDistributed build service\nstage.debusine.qualcomm.com"] --> WS

    WS["Debusine workspace\nBuilt .deb packages"] --> CHDIST

    CHDIST["chdist + apt-get download\nIsolated apt env\nNo installation"] --> S3

    S3["S3\nqli-prd-lecore-gh-artifacts"]
```

---

## Ubuntu Path — Docker

```mermaid
flowchart LR
    ART["kernel-srcpkg artifact"] --> EXT

    EXT["tar xzf --strip-components=1\nRestore execute permissions\nkernel-source/"] --> BK

    BK["build-kernel.sh\n--skip-prepare\n--local-source kernel-source/\n--build-mode docker\n\ndocker run pkg-builder:DISTRO\ndpkg-buildpackage -b"] --> S3

    S3["S3\nqli-prd-lecore-gh-artifacts"]
```

> `--skip-prepare` is safe because `prepare-source.sh` already ran in the `prepare` job.
> `debian/control`, `debian/changelog`, and all config fragments are baked into the artifact.

---

## Build Outputs

| Package | Contents | Install |
|---|---|---|
| `linux-image-<kver>-qcom_<ver>_arm64.deb` | Kernel image, `.config`, DTBs, modules | **Required** |
| `linux-headers-<kver>-qcom_<ver>_arm64.deb` | Headers for out-of-tree modules (DKMS) | Optional |
| `linux-image-<kver>-qcom-dbg_<ver>_arm64.deb` | Full debug symbols (`vmlinux`, per-module) | Optional |
| `*.buildinfo` | Reproducible build metadata | Do not install |
| `*.changes` | Upload manifest | Do not install |

### S3 Path

| Path | Build type |
|---|---|
| `s3://qli-prd-lecore-gh-artifacts/<org>/pkg/debusine/<repo>/<suite>/<run_id>-<run_attempt>/` | Debian (Debusine) — suite segment included |
| `s3://qli-prd-lecore-gh-artifacts/<org>/pkg/temp/<repo>/<run_id>-<run_attempt>/` | Ubuntu (docker) — flat layout, no suite segment |

### Install

```bash
sudo dpkg -i linux-image-<kver>-qcom_<ver>_arm64.deb

# Optional: headers for DKMS / out-of-tree modules
sudo dpkg -i linux-headers-<kver>-qcom_<ver>_arm64.deb
```

---

## Repository Variables and Secrets

### Repository Variables (`vars.*`)

| Variable | Value | Used by |
|---|---|---|
| `DEBUSINE_HOST` | `stage.debusine.qualcomm.com` | `debusine-build`, `upload-artifacts` |
| `DEBUSINE_SCOPE` | `qualcomm` | `debusine-build`, `upload-artifacts` |
| `DEBUSINE_PARENT_WORKSPACE` | `qli-ci` | `debusine-build` |

### Secrets (`secrets.*`)

| Secret | Used by |
|---|---|
| `DEBUSINE_USER` | `debusine-build`, `upload-artifacts` |
| `DEBUSINE_TOKEN` | `debusine-build`, `upload-artifacts` |

---

## Deprecation Path

When Debusine gains Ubuntu support:

```
1. Delete  .github/workflows/build-kernel-ubuntu.yml
2. Remove  ubuntu-build job from build-kernel-deb.yml  (3 lines)
3. Update  ci/build-matrix.json  (change resolute entry if needed)
```

Zero changes to `build-kernel-deb.yml` orchestration logic, `prepare-source.sh`, or `debian/`.

---

## License

pkg-linux-kernel is licensed under the BSD-3-clause License. See LICENSE.txt for the full license text.
