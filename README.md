## Kernel Build Workflow

The `build-kernel` workflow builds the `qualcomm-linux/kernel` into a single Debian package and publishes it to dedicated S3 bucket location, together with a metadata file that captures how the package was produced.

The same pipeline is used in two modes:
- **Manual runs** (on demand, via GitHub UI)
- **Nightly runs** (scheduled, with fixed defaults)


```mermaid
graph TD
  A[Manual run GitHub UI] --> B[workflow dispatch]ascacac
  S[Nightly run 9PM PST] --> T[schedule event]

  B --> C[Manual inputs]
  C --> I1[qcom-build-utils ref]
  C --> I2[kernel branch]
  C --> I3[qcom next PRs optional]
  C --> I4[kernel topics PRs optional]

  T --> D[Use default inputs]
  D --> J1[ref main]
  D --> J2[qcom-next]
  D --> J3[no PR overrides]

  I1 --> P[Kernel build and deb packaging*]
  I2 --> P
  I3 --> P
  I4 --> P

  J1 --> P
  J2 --> P
  J3 --> P

  P --> O1[kernel deb package]
  P --> O2[build info metadata]

  O1 --> S3[s3 bucket]
  O2 --> S3
```
*via qcom-build-utils kernel build tools

#### NOTE: Planned Migration to Native Debian Tooling

The current workflow relies on qcom-build-utils for kernel build orchestration and Debian package generation. There is ongoing work to migrate this flow to a native `dpkg-buildpackage`-based process with proper Debian metadata, which will eventually replace the existing qcom-build-utils kernel build tooling. This README documents the current state; the documentation will be updated as the new packaging flow is rolled out.


### 1. Trigger Modes

#### Manual Run

* Triggered from **GitHub Actions → Run workflow**.
* Event: `workflow_dispatch`.
* The operator can set or override all inputs:

  * `qcom-build-utils-ref`
  * `kernel-branch`
  * `qcom-next-pr`
  * `kernel-topics-pr`
* Typical use cases:

  * Test a specific `qcom-build-utils` ref or kernel branch/tag.
  * Integrate specific PRs from `qcom-next` and/or `kernel-topics`.

#### Scheduled Run (Nightly)

* Triggered by cron:

  ```yaml
  schedule:
    - cron: '0 5 * * *'  # 05:00 UTC ≈ 9:00 PM PST
  ```

* Event: `schedule`.

* Always uses **default inputs**:

  * `qcom-build-utils-ref = main`
  * `kernel-branch = qcom-next`
  * `qcom-next-pr = ""` (no qcom-next PRs merged)
  * `kernel-topics-pr = ""` (no kernel-topics patches applied)

* Purpose:

  * Produce a **clean nightly kernel build** from the standard branch.

---

### 2. Inputs

#### Workflow Inputs (`workflow_dispatch`)

All inputs are optional; defaults are used when omitted. The scheduled run always behaves as if all defaults were chosen.

* **`qcom-build-utils-ref`**
  Branch, tag, or SHA for `qualcomm-linux/qcom-build-utils`.
  **Default:** `main`

* **`kernel-branch`**
  Branch or tag to sync from `qualcomm-linux/kernel`.
  **Default:** `qcom-next`

* **`qcom-next-pr`**
  Space-separated list of PR numbers to merge from `qcom-next`.
  **Default:** `""` (no PR overrides)

* **`kernel-topics-pr`**
  Space-separated list of PR numbers from `kernel-topics` to apply as patches.
  **Default:** `""` (no topic patches)

#### Secrets

* **`DEB_PKG_BOT_CI_TOKEN`**
  Required to check out `qcom-build-utils` and related private resources.

* **`PAT`**
  Used inside the scripts to fetch from `qualcomm-linux/kernel` and PR refs.

---

### 3. Build Pipeline (Kernel Build and Deb Packaging)

The job runs on a **self-hosted ARM64 runner**:

1. **Checkout and Environment Setup**

   * Check out the current repository.
   * Derive:

     * `ORG_NAME` from `GITHUB_REPOSITORY` (string before `/`)
     * `REPO_NAME` from `GITHUB_REPOSITORY` (string after `/`)
   * Check out `qualcomm-linux/qcom-build-utils` at `qcom-build-utils-ref`.
   * Record the build-utils HEAD SHA:

     ```bash
     QCOM_BUILD_UTILS_SHA=$(git rev-parse HEAD)
     ```

2. **Kernel Sync**

   In `qcom-build-utils/kernel`:

   * Set `BUILD_TOP` and export `build_top` into the environment.
   * Sync `qualcomm-linux/kernel` into `"$BUILD_TOP/qcom-next"`:

     * Detect if `KERNEL_BRANCH` is a **branch** or a **tag** (via `git ls-remote`).
     * Fetch the appropriate ref with `--depth=1` and check it out.
   * Record kernel HEAD SHA:

     ```bash
     QCOM_KERNEL_SHA=$(git rev-parse HEAD)
     ```

3. **Optional PR Integration**

   * If `qcom-next-pr` is non-empty:

     * For each PR:

       * Fetch `pull/<PR>/head` into a local branch `pr-<PR>`.
       * Attempt `git merge pr-<PR> --no-commit`.
       * On conflict: `git merge --abort` and **fail the job**.
   * If `kernel-topics-pr` is non-empty:

     * For each PR:

       * Download `https://github.com/qualcomm-linux/kernel-topics/pull/<PR>.patch`.
       * Apply with `git am`.
       * On failure: `git am --abort` and **fail the job**.

4. **Kernel Configuration**

   Ensure SquashFS and related options are enabled before building:

   ```bash
   ./scripts/enable_squashfs_configs.sh "$BUILD_TOP/qcom-next/"
   ```

5. **Kernel Build**

   Inside the build environment (via the kmake image), run:

   ```bash
   ./scripts/build_kernel.sh
   ```

   This compiles the kernel using the synced (and optionally patched) tree under `qcom-build-utils/kernel`.

6. **Debian Package Build**

   Still inside the build environment:

   ```bash
   ./scripts/build-kernel-deb.sh out/ "${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
   mkdir -p deb_artifact
   cp ./*.deb deb_artifact/
   ```

   This produces one kernel `.deb` package and deploys that under `deb_artifact/`.

7. **Metadata Generation**

   Generate a `build_info` file that captures provenance and configuration:

   * File path: `qcom-build-utils/kernel/deb_artifact/build_info`
   * Contents include (examples):

     * `JOB_ID` and `JOB_ATTEMPT`
     * `ORG_NAME`, `REPO_NAME`
     * `QCOM-BUILD-UTILS BRANCH/TAG` and `HEAD SHA`
     * `KERNEL BRANCH/TAG` and `HEAD SHA`
     * `PRs FROM QCOM-NEXT`
     * `PRs FROM KERNEL TOPICS`

---

### 4. Outputs and S3 Layout

The workflow produces two key outputs:

1. **Kernel Debian package**

   * Location before upload:
     `qcom-build-utils/kernel/deb_artifact/*.deb`

2. **Build metadata file**

   * Location before upload:
     `qcom-build-utils/kernel/deb_artifact/build_info`

These are uploaded to a **private S3 bucket** using `upload-private-artifact-action`.

* **Bucket name:**

  ```text
  qli-prd-lecore-gh-artifacts
  ```

* **Final object path template:**

  ```text
  s3://qli-prd-lecore-gh-artifacts/${ORG_NAME}/pkg/temp/${REPO_NAME}/${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}/
  ```

Under that path you will typically find:

* `*.deb` – the built kernel Debian package
* `build_info` – metadata describing exactly what was built (refs, SHAs, PRs, job IDs)

This structure makes it easy to:

* Trace each artifact back to the originating GitHub Actions run.
* See exactly which inputs and PRs were used.
* Consume the `.deb` packages in downstream systems (image builds, testing pipelines, etc.).

---

## License

pkg-linux-kernel is licensed under the BSD-3-clause License. See LICENSE.txt for the full license text.
