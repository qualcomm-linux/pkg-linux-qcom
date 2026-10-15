# Building the kernel packages locally

This guide builds the same Debian packages CI publishes, from the same
packaging, on your own machine. The quick start covers the common case. The
sections after it cover reproducing a CI build exactly, testing local kernel
changes, the out-of-tree modules, and native builds.

Run every command from the root of a `pkg-linux-qcom` checkout unless a step
says otherwise.

## Requirements

- **An arm64 (aarch64) Linux host.** The packaging builds natively and does not
  cross-compile, and `docker-pkg-build` refuses any other host architecture.

## Quick start

Docker mode is the default and the recommended way to build. The build runs in
the `docker-pkg-build` builder image, so the host only needs Docker and the few
tools that prepare the source tree.

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

3. Clone this repository and build the newest `qcom-next` tag for Debian trixie:

   ```bash
   git clone https://github.com/qualcomm-linux/pkg-linux-qcom
   cd pkg-linux-qcom
   ./build-kernel.sh --latest-tag
   ```

The packages land in `kernel-build/trixie/`:

| Package | Contents |
| --- | --- |
| `linux-image-<KVER>` | The kernel, its modules under `/usr/lib/modules/<KVER>/`, and the device trees |
| `linux-image-qcom-next` | Metapackage that depends on `linux-image-<KVER>` |
| `linux-headers-<KVER>` | Headers for building out-of-tree modules against this kernel |
| `linux-headers-qcom-next` | Metapackage that depends on `linux-headers-<KVER>` |
| `linux-image-<KVER>-dbg` | Debug symbols for the kernel and its modules |

`<KVER>` is the kernel release, `uname -r` on the device, for example
`7.3.0-rc4+qcom-next-20261014-g1a0586064ee1`: the kernel version, the variant,
the tag's date and the commit. See [version.md](version.md) for the scheme.

The first build for a suite also builds its builder image,
`ghcr.io/qualcomm-linux/pkg-builder:<suite>`, from the Dockerfile in
`docker-pkg-build`, because the published image is not publicly pullable. That
takes about 6 minutes and 2 GB, once per suite.

`build-kernel.sh` clones the kernel shallowly into `kernel-source/`, copies
`debian/` into it, derives the version from the tag the same way CI does, and
builds the packages with sbuild inside the builder image. Running it again
reuses `kernel-source/` and fetches whatever ref you ask for.

## Choosing what to build

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
- `kernel-source/` remembers the repository it was cloned from. To build from a
  different `--repo`, add `--clean` to start from a fresh clone.

## Matching a CI build

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
`prepare-source.sh`, then build the prepared tree. This needs `jq`:

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
./build-kernel.sh --local-source "kernel-$VARIANT" --skip-prepare --distro "$SUITE"
```

The kernel release, package names and version come out as CI's daily build of
the same commit. The recipe reads the Daily row on purpose: release versions
are published only by CI, and a local build of one would have the same name
and version as the released package with different contents.

## Testing local kernel changes

Point `--local-source <dir>` at your kernel tree.

- A tree build, in Docker or native mode, builds the working tree as it is,
  so **uncommitted changes are built**. In Docker mode the tree is packed into
  the source tarball, so untracked files go in too: everything except `.git/`
  and `debian/`.
- The version still names the HEAD commit. A build of a commit that CI also
  built gets **the same package names as CI's**, and its `0qcom1` revision
  sorts below CI's, so on a device that also has the Qualcomm package
  repository, apt replaces your kernel with CI's. Add `--kver-extra -dev` (or
  any suffix) to give your build its own kernel release and package names.
- `--source-package` works the other way: it packs exactly the committed
  tree, and refuses a tree with changes outside `debian/`. Commit first if you
  want that path.

## Out-of-tree modules

`--dkms` builds out-of-tree kernel modules against the kernel being built, from
their `<name>-dkms` packages. Each module ships in its own packages rather than
in `linux-image-<KVER>`:

| Package | Contents |
| --- | --- |
| `<name>-modules-<KVER>` | The modules, under `/usr/lib/modules/<KVER>/updates/qli/` |
| `<name>-modules-<KVER>-dbg` | Their debug symbols |
| `linux-image-qcom-next-modules-<name>` | Metapackage that follows the newest kernel |
| `linux-image-qcom-next-modules` | Metapackage for the whole set |

The metapackage names are `qcom-next`'s. Other variants use their own, for
example `linux-image-qcom-next-debug-modules-kgsl`.

**In Docker mode** this needs no setup: the builder image's build environment
already has the Qualcomm package repositories the `-dkms` packages come from.

**In native mode** add the Qualcomm Linux repository first. It is signed with
the key `docker-pkg-build` ships, and the modules live in both `main` and
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
kernel, and may print a message about missing headers for it. That does not
affect the package build.

## Building from a source package

CI builds every package from a Debian source package rather than from a tree.
The same is available locally, and it is the way to rebuild exactly what a
source package describes:

```bash
./build-kernel.sh --latest-tag --source-package
./build-kernel.sh --dsc kernel-build/trixie/linux-qcom-next_*.dsc
```

The first command stops after writing the `.orig.tar.gz`, `.debian.tar.xz`,
`.dsc` and `_source.changes` to `kernel-build/trixie/`. It only needs `git`,
`make` and `dpkg-dev` on the host, no Docker. The orig tarball is reproducible:
two runs on one commit produce the same file, byte for byte.

## Native builds

`--build-mode native` runs `dpkg-buildpackage` on the host instead of in a
container. Use it when the host runs the release you are building for, since
the packages are built with the host's toolchain.

1. Install the build dependencies:

   ```bash
   sudo apt install build-essential devscripts fakeroot git debhelper bc bison flex \
     libssl-dev libelf-dev dwarves python3 kmod cpio rsync pkg-config make
   ```

2. Build:

   ```bash
   ./build-kernel.sh --latest-tag --build-mode native
   ```

- The packaging needs debhelper 13.11.9 or newer, so the host must be trixie
  or newer, or Ubuntu 24.04 or newer. Debian bookworm and Ubuntu 22.04 are too old.
- A native build compiles inside `kernel-source/` and leaves its objects there.
  Clean them before building that tree in Docker mode or as a source package:

  ```bash
  git -C kernel-source checkout -- . && git -C kernel-source clean -xdf -- . ':(exclude)debian'
  ```

- The build uses every CPU by default. Set `PARALLEL=<n>` in the environment
  to use fewer. `DEB_BUILD_OPTIONS=parallel=<n>` is not read.

`--build-mode sbuild` runs sbuild on the host against a chroot you have already
set up for the suite. Docker mode runs the same sbuild inside the builder image
with nothing to set up, so prefer it.

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
| `... differs from commit <sha> outside debian/` | A source package must describe a commit. Commit your changes, or clean the tree with the command the error prints. |
| `Repo mismatch at .../kernel-source` | `kernel-source/` was cloned from another repository. Add `--clean`. |
| `In-tree fragment not found` | The `intree:` path is relative to the kernel source root and must exist in the tree you are building. |
