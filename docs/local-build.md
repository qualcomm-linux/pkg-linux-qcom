# Building the kernel packages locally

This guide builds the same Debian packages CI publishes, from the same
packaging, locally. A build has the same two stages as CI:

1. **The source package.** Clone the kernel, add the packaging, derive the
   version and pack it all into a Debian source package (`.dsc`).
2. **The binary packages.** Build the `.deb` files from that `.dsc`.

The sections after the quick start cover each stage, reproducing a CI build
exactly, testing local kernel changes, and installing the result.

Run every command from the root of a `pkg-linux-qcom` checkout unless a step
says otherwise.

## Requirements

- **An arm64 (aarch64) Linux host.** The packaging builds natively and does not
  cross-compile, and `docker-pkg-build` refuses any other host architecture.

## Quick start

Docker mode is the default and the recommended way to build. The binary build
runs in the `docker-pkg-build` builder image, so the host only needs Docker and
the few tools that prepare the source.

1. Install Docker and those tools, and let your user run Docker:

   ```bash
   sudo apt install docker.io git make dpkg-dev
   sudo usermod -aG docker "$USER"
   ```

   Log out and back in so the group change applies. Until then `docker ps`
   fails, and `build-kernel.sh` stops to ask whether to run Docker with sudo.

2. Clone the builder tooling into your home directory, where `build-kernel.sh`
   finds it without any flag:

   ```bash
   git clone https://github.com/qualcomm-linux/docker-pkg-build ~/docker-pkg-build
   ```

3. Clone this repository, build the source package for the newest `qcom-next`
   tag for Debian trixie, then the binary packages from it:

   ```bash
   git clone https://github.com/qualcomm-linux/pkg-linux-qcom
   cd pkg-linux-qcom
   ./build-kernel.sh --latest-tag --source-package
   ./build-kernel.sh --dsc kernel-build/trixie/linux-qcom-next_*.dsc
   ```

Both stages write to `kernel-build/trixie/`. The packages are the ones listed
in [Packages](../README.md#packages). `<KVER>` in their names is the kernel
release, `uname -r` on the device, for example
`7.3.0-rc4+qcom-next-20261014-g1a0586064ee1`: the kernel version, the variant,
the tag's date and the commit. See [version.md](version.md) for the scheme.

## Stage 1: the source package

```bash
./build-kernel.sh --latest-tag --source-package
```

`build-kernel.sh` clones the kernel shallowly into `kernel-source/`, copies
`debian/` into it, derives the version from the tag the same way CI does, and
writes the `.orig.tar.gz`, `.debian.tar.xz`, `.dsc` and `_source.changes` to
`kernel-build/<suite>/`. It ends by printing the command for stage 2.

This stage needs only `git`, `make` and `dpkg-dev` on the host, no Docker. The
orig tarball is reproducible: two runs on one commit produce the same file,
byte for byte. It is packed from the commit, so a tree with changes outside
`debian/` is refused. To build changes you have not committed, see
[Testing local kernel changes](#testing-local-kernel-changes).

Running it again reuses `kernel-source/` and fetches whatever ref you ask for.

### Choosing what to build

These options select the source, so they go on the stage 1 command:

| To build | Add |
| --- | --- |
| The newest `qcom-next` tag | `--latest-tag` |
| A specific tag | `--tag qcom-next-7.3-rc4-20261014` |
| A branch tip | `--branch qcom-next`, which is also what you get with no tag option |
| From a fork | `--repo <url>`, with `--tag` or `--branch` |
| A kernel tree you already have | `--local-source <dir>` |
| Another suite | `--distro forky` or `--distro resolute` (trixie is the default) |
| The debug configuration | `--kernel-config intree:arch/arm64/configs/qcom_debug.config,intree:kernel/configs/debug.config` |
| The out-of-tree modules | `--dkms kgsl,camx,iris-vpu,audioreach` |
| A distinct kernel release | `--kver-extra -dev`, see [Testing local kernel changes](#testing-local-kernel-changes) |

- `--latest-tag` only looks at `qcom-next-*` tags. For another kernel line,
  find its newest tag and pass it with `--tag`:

  ```bash
  ci/scripts/resolve-kernel-ref.sh --url https://github.com/qualcomm-linux/kernel --latest-tag 'qcom-7.2-*'
  ```

- Every fragment in `debian/config-available/` is applied to every build.
  `--kernel-config` only adds fragments beyond that set, today the in-tree
  debug fragments.
- `--dkms` builds out-of-tree kernel modules against the kernel, from their
  `<name>-dkms` packages, into packages of their own.
- `kernel-source/` remembers the repository it was cloned from. To build from a
  different `--repo`, add `--clean` to start from a fresh clone.
- For any suite other than trixie, pass the same `--distro` to stage 2.

### Matching a CI build

CI builds one leg per row and suite in `ci/build-matrix.json`. The quick start
matches CI's trixie build of `qcom-next` in everything but three ways:

- **The out-of-tree modules.** CI builds `kgsl,camx,iris-vpu,audioreach` for
  trixie and forky, and `kgsl` for resolute. Add the matching `--dkms` list.
- **Package names** for every variant other than `qcom-next`.
  `build-kernel.sh` always names the source package `linux-qcom-next` and the
  metapackage `linux-image-qcom-next`.
- **The Debian revision.** A local build uses `0qcom1`, CI uses the matrix
  stub plus a per-suite suffix, for example `0qli1~bpo13+1~` for a trixie
  daily.

To reproduce a CI leg exactly, read its inputs from the matrix and pass them to
`prepare-source.sh`, then build the source package from the prepared tree. This
needs `jq`:

```bash
VARIANT=qcom-next-debug SUITE=trixie
ROW=$(ci/scripts/resolve-matrix.sh --type Daily --kernel-variant "$VARIANT" --single-suite "$SUITE" | jq -c '.[0]')
get() { jq -r ".$1 // empty" <<< "$ROW"; }

if [[ "$(get ref_strategy)" == latest_tag ]]; then
  REF=$(ci/scripts/resolve-kernel-ref.sh --url "$(get git_clone)" --latest-tag "$(get tag_pattern)")
else
  REF=$(get branch_or_tag)
fi

git clone --depth 1 --branch "$REF" "$(get git_clone)" "kernel-$VARIANT"
./prepare-source.sh --source-dir "kernel-$VARIANT" --distro "$SUITE" \
  --flavour "$VARIANT" \
  --srcpkg "$(get srcpkg)" --binpkg "$(get binpkg)" \
  --debian-revision "$(get debian_revision)" \
  --kernel-config "$(get kernel_config)" \
  --dkms "$(get dkms)"
./build-kernel.sh --local-source "kernel-$VARIANT" --skip-prepare --distro "$SUITE" --source-package
```

Then run stage 2 with the command it prints. The kernel release, package names
and version come out as CI's daily build of the same commit. The recipe reads
the Daily row on purpose: release versions are published only by CI, and a
local build of one would have the same name and version as the released
package with different contents.

## Stage 2: the binary packages

```bash
./build-kernel.sh --dsc kernel-build/trixie/<source>.dsc
```

The `.orig.tar.gz` and `.debian.tar.xz` the `.dsc` names must sit beside it,
where stage 1 writes them. Add `--distro` for any suite other than trixie.

### In Docker

The default. The `.dsc` is built with sbuild in the builder image for the
suite, `ghcr.io/qualcomm-linux/pkg-builder:<suite>`, which is how CI builds
resolute. The image's build environment already has the Qualcomm package
repositories the out-of-tree modules' `-dkms` packages come from.

The first build for a suite also builds that image from the Dockerfile in
`docker-pkg-build`, because the published image is not publicly pullable. That
takes about 6 minutes and 2 GB, once per suite.

### Native

`--build-mode native` unpacks the `.dsc` into the output directory and runs
`dpkg-buildpackage` on the host. Use it when the host runs the release you are
building for, since the packages are built with the host's toolchain.

1. Install the build dependencies:

   ```bash
   sudo apt install build-essential devscripts fakeroot git debhelper bc bison flex \
     libssl-dev libelf-dev dwarves python3 kmod cpio rsync pkg-config make
   ```

2. For a source package built with `--dkms`, add the Qualcomm Linux repository
   and install the `-dkms` packages. The repository is signed with the key
   `docker-pkg-build` ships, and the modules live in both `main` and
   `contrib`:

   ```bash
   sudo install -D -m 644 ~/docker-pkg-build/Dockerfiles/keyrings/debusine.asc /etc/apt/keyrings/debusine.asc
   sudo tee /etc/apt/sources.list.d/qli.sources <<'EOF'
   Types: deb
   URIs: https://deb.debusine.qualcomm.com/qualcomm/qli
   Suites: trixie
   Components: main contrib
   Signed-By: /etc/apt/keyrings/debusine.asc
   EOF
   sudo apt update
   sudo apt install dkms kgsl-dkms camx-dkms iris-vpu-dkms audioreach-dkms
   ```

   Installing a `-dkms` package also tries to build it for the host's running
   kernel, and may print a message about missing headers for it. That does
   not affect the package build.

3. Build:

   ```bash
   ./build-kernel.sh --dsc kernel-build/trixie/<source>.dsc --build-mode native
   ```

- The packaging needs debhelper 13.11.9 or newer, so the host must be trixie
  or newer, or Ubuntu 24.04 or newer. Debian bookworm and Ubuntu 22.04 are too old.
- The build uses every CPU by default. Set `PARALLEL=<n>` in the environment
  to use fewer. `DEB_BUILD_OPTIONS=parallel=<n>` is not read.

`--build-mode sbuild` runs sbuild on the host against a chroot you have already
set up for the suite. Docker mode runs the same sbuild inside the builder image
with nothing to set up, so prefer it.

## Testing local kernel changes

A source package describes a commit, so stage 1 refuses uncommitted changes.
To build a kernel tree as it is, skip the source package and build the tree
directly, in one step:

```bash
./build-kernel.sh --local-source <dir> --kver-extra -dev
```

- **Uncommitted changes are built.** In Docker mode the tree is packed into a
  source tarball of its own, so untracked files go in too: everything except
  `.git/` and `debian/`. That tarball is not reproducible, so use the two
  stages for anything you want to rebuild exactly.
- The version still names the HEAD commit. Without `--kver-extra`, a build of
  a commit that CI also built gets **the same package names as CI's**, and its
  `0qcom1` revision sorts below CI's, so on a device that also has the
  Qualcomm package repository, apt replaces your kernel with CI's.
  `--kver-extra -dev` (or any suffix) gives your build its own kernel release
  and package names.
- The options in [Choosing what to build](#choosing-what-to-build) apply here
  too, and `--build-mode native` builds the tree on the host. A native tree
  build compiles inside the tree and leaves its objects there. Clean them
  before building that tree in Docker mode or as a source package:

  ```bash
  git -C <dir> checkout -- . && git -C <dir> clean -xdf -- . ':(exclude)debian'
  ```

## Installing the packages

Install with apt rather than `dpkg -i`, so the kernel's dependencies are pulled
in. From the output directory, set `KVER` to the kernel release in the file
names, then install the kernel and, optionally, its metapackage:

```bash
cd kernel-build/trixie
KVER=7.3.0-rc4+qcom-next-20261014-g1a0586064ee1
sudo apt install ./linux-image-${KVER}_*.deb ./linux-image-qcom-next_*.deb
```

Add `./linux-headers-${KVER}_*.deb` to build out-of-tree modules on the device,
and `./<name>-modules-${KVER}_*.deb` for the out-of-tree modules you built. Keep
the braces in `${KVER}`: without them the shell reads `$KVER_` as the variable
name.

The kernel installs to `/boot/vmlinuz-<KVER>` with its `config` and
`System.map`, and its modules to `/usr/lib/modules/<KVER>/`. Kernels of
different releases install side by side. To list and remove them:

```bash
dpkg -l 'linux-image-*qcom*'
sudo apt remove linux-image-${KVER}
```

## Troubleshooting

| Message | Cause and fix |
| --- | --- |
| `Docker requires sudo. Run with sudo? (y/N)` | Your user cannot reach Docker yet. Add it to the `docker` group and log out and back in. |
| `docker_deb_build.py not found` | `docker-pkg-build` is not in `~/docker-pkg-build`. Clone it there, or pass `--docker-build <path>`. |
| `Unsupported host architecture` | `docker-pkg-build` runs on arm64 hosts only. Build on an arm64 host. |
| `ERROR: Invalid JSON in ci/build-matrix.json` | `jq` is not installed. The matrix scripts need it. |
| `make: command not found` | The source preparation runs on the host in every mode. Install `git make dpkg-dev`. |
| `dpkg-parsechangelog not found` | Install `dpkg-dev` and `git` on the host. |
| `... differs from commit <sha> outside debian/` | A source package must describe a commit. Commit your changes, clean the tree with the command the error prints, or build the tree directly as in [Testing local kernel changes](#testing-local-kernel-changes). |
| `Repo mismatch at .../kernel-source` | `kernel-source/` was cloned from another repository. Add `--clean`. |
| `In-tree fragment not found` | The `intree:` path is relative to the kernel source root and must exist in the tree you are building. |
