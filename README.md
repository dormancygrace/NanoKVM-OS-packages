# NanoKVM OS packages

This repository is the canonical source for optional NanoKVM OS packages. It
owns recipes, target compilation, APKv3 package creation, signed repository
indexes and CI. The Enhanced firmware repository owns the runtime manager and
the versioned target contract; it consumes a pinned commit from this
repository.

Packages target the NanoKVM OS Buildroot `riscv64`/musl ABI. Alpine packages,
host libraries, base libc, kernel/modules, updater files and base system services
are outside this repository's ownership. Every addon package depends on an
exact `nkos-base-abi=<version>`, `nkos-server-api=1` and its declared immutable
feature providers. The resolver cannot substitute a repository-defined base
ABI provider because those providers are installed by the signed complete OS
image. The explicit compatibility version is `BASE_ABI_VERSION` in
`versions.env`; it is deliberately independent from OS release labels.

Payload ownership is strict: files are below `addons/<id>/` in the package and
become `/opt/nkos/addons/<id>/` at runtime. Configuration and data live at
`/etc/kvm/<id>` and `/data/<id>` and are created and retained by the central
manager. Package scripts, triggers and rootfs paths are rejected by
`scripts/validate-repository.py` and are disabled by the runtime manager.
Service descriptors are declarative; the manager controls their lifecycle and
default-disabled services remain stopped until explicitly enabled.

The `nkos-addon-hello` recipe is a small static lifecycle fixture used to prove
the compiler, namespace, dependency and service descriptor paths. The
`nkos-addon-system-info` recipe is a useful static diagnostic command that
reports the running kernel and machine. Real addons must carry their upstream
source/version and an explicit independent APK package revision; a
packaging-only fix publishes the same upstream version with a higher revision
rather than replacing an existing package.

## Reproducible build

`versions.env` pins apk-tools and its source digest. `scripts/build-apk-tools.sh`
builds that exact tag from source with Meson and no Alpine binary repository.
The publish workflow also downloads a hash-checked Buildroot source archive and
builds its own `riscv64`/musl toolchain with
`scripts/build-riscv-toolchain.sh`; it never expects a machine-local compiler
or installs a prebuilt target SDK.
The workflow has two process boundaries.
`scripts/build-package-staging.sh` validates versions with native apk-tools and compiles recipes into a
hash-recorded unsigned staging artifact with no signing key in its
environment. `scripts/sign-repository.sh` validates that artifact against the checked-out recipe metadata, signs
each package and the `riscv64/Packages.adb` index, and never runs a recipe build hook.
`scripts/build-repository.sh` requires the resulting `apk` executable, an
explicit exact target ABI, the RISC-V target compiler for each recipe and the
existing production signing key path. It writes a fresh `repository/` tree,
creates `riscv64/Packages.adb` with `apk mkndx --sign-key`, and records package
SHA-256 hashes and the package-repository commit in `manifest.json`.

The currently authorized production key is RSA4096 and is supplied only by the
controlled CI secret `APK_SIGNING_KEY`; it is never committed. `keys/` contains
the matching public trust key (`nanokvm-os-packages-rsa4096.pem`, DER SHA-256
fingerprint `447af70c2e1f12de0e61731113bdbc6d319e31335934d909424ef65fa129a001`).
The build and verification path remains algorithm-agile: supported APK key
formats are selected by apk-tools and must have matching public trust material.
Pull requests use a throwaway key in a temporary directory. The production OS
release key is separate and remains Ed25519. `scripts/host-self-test.sh`
verifies a signed fixture index, exact dependency metadata, payload ownership
and rejection of a script or system path without touching the production key.

```text
scripts/build-apk-tools.sh --source-dir /path/to/apk-tools --out /tmp/apk
NKOS_TARGET_CC=/path/to/riscv64-buildroot-linux-musl-gcc \
  scripts/build-repository.sh --apk /tmp/apk --base-abi nkos-base-abi=1.0.0 \
  --sign-key /secure/ci/APK_SIGNING_KEY.pem --out repository
scripts/host-self-test.sh --apk /tmp/apk
```

The public repository workflow performs validation and the isolated host gate
on every change. A signed Pages repository is built only by an explicit
workflow dispatch with `publish=true`, the protected `package-publishing`
environment and the existing secret. The output is published below the
stable `/repository/` path; OS images remain on the separate release channel.

Publication is append-only by package identity. `build-repository.sh` creates a
new output tree and never updates an existing path. CI must reject a changed
hash for an already published `(name, version, arch)` tuple and retain every
APK still referenced by an index. Packaging fixes therefore increment the
independent package revision (`upstream_version-rN`) and cannot silently
replace an existing artifact.

## Optional utilities (image sequence 18 and later)

`mc`, `superfile`, `nano`, `htop`, `tcpdump`, `ethtool` and `bluez5-utils`
are optional APKs with IDs of the same name and package names `nkos-addon-<id>`.
Each starts at upstream version `-r1`. The recipe's independent `pkgrel` must
increase for packaging fixes. `superfile` declares `nkos-addon-nano>=9.2-r1`:
apk resolves and installs its default editor automatically.

These packages require `nkos-feature-private-libs-riscv64=1`. The image supplies
the RISC-V musl interpreter; other ELF libraries travel in the package's own
`lib/` directory. Every ELF has a fixed package-local RUNPATH, and the runtime
validates architecture, interpreter, library paths and the complete private
dependency closure before committing. Libraries are bundled, not installed in
`/usr/lib`; old static-only images reject the missing feature cleanly.

The firmware build exports its optional source-built userspace with
`python3 scripts/export-optional-packages.py --buildroot-output OUTPUT
--mc-prefix MC_DESTDIR --out INPUT`. Build mc with its prefix set to
`/opt/nkos/addons/mc/usr`, sysconfdir `/opt/nkos/addons/mc/etc`, and libexecdir
`/opt/nkos/addons/mc/usr/libexec`. Preserve the firmware's compiler and `-O2`
flags. The exporter copies resources, expands aliases, includes license texts,
records each library owner, relocates ELF RUNPATH and hashes the payload.
Set `NKOS_OPTIONAL_INPUT=INPUT` when running build-package-staging.sh.

The release `optional-inputs-beta7-seq18` contains this hash-pinned binary input
and corresponding upstream source archives, Buildroot configuration and patches.
CI imports the exact input pinned in versions.env into unsigned staging before
the separate secret-backed signer runs. Importing a built firmware component is
an explicit build boundary; it is not a download of Alpine binaries. A future
firmware/toolchain rebuild must export a new input, update its pin and increment
the affected package revisions. The existing two static recipes still compile
from source in package CI.

After installation, new SSH/web terminal sessions add installed `bin/` directories
to PATH. An existing shell can run `. /etc/profile`. Commands are also available
through `nkos-addons run <id> -- /opt/nkos/addons/<id>/bin/<command>`.
BlueZ's `bluetooth` service is disabled by default and runs its own D-Bus instance;
its tools use that bus automatically. Bond keys and configuration stay in
`/etc/kvm/bluez5-utils`, with Unix permissions on the root filesystem. No Bluetooth
adapter is required to install the utilities. A real Bluetooth connection still
requires compatible hardware.

## Optional Python

Install `nkos-addon-python` through the image's addon manager:

```sh
nkos-addons install python
. /etc/profile
python --version
pip --version
```

The `python` and `python3` commands run the same CPython 3.14.7 interpreter.
Both `pip` and `pip3` invoke its bundled pip 26.2.1. Python stays outside the
base image, with private OpenSSL 4.0.2, Expat, libffi and zlib libraries.
Default pip installations persist in `/data/python`; add `/data/python/bin`
to PATH when using console commands installed by pip. Removing the APK keeps
this data. Virtual environments requiring symlinks need a POSIX filesystem;
the normal `/data` filesystem is exFAT.

Package CI uses the independent `NKOS_PYTHON_INPUT` export pinned in
`versions.env`, preserving existing optional utility inputs and revisions.
See [the Python build notes](recipes/nkos-addon-python/BUILD.md) for source
archives, build configuration, the OpenSSL compatibility patch and export steps.
