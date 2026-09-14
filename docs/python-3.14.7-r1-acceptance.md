# Python 3.14.7-r1 acceptance

Date: 2026-09-14. Device: NanoKVM SG2002 PCIe/UXC, NanoKVM OS beta-10
sequence 23, Linux `7.2.5-nanokvm-os-r3`.

## Published package

- Recipe/input commit: `7a6aa4d641998c8db0dd19b8c089a53c61ae0b78`.
- Package: `nkos-addon-python-3.14.7-r1.apk`, riscv64/musl, target `-O2`.
- APK SHA-256: `90f25dff5888bcf271c50d73d45ae4a4082bced722decea88844d51d6ea17fe9`.
- [Publication run](https://github.com/dormancygrace/NanoKVM-OS-packages/actions/runs/34870359162):
  host validation, target staging, signing and Pages deployment all passed.
- [Pinned binary input and corresponding sources](https://github.com/dormancygrace/NanoKVM-OS-packages/releases/tag/python-input-3.14.7-r1).

The package contains CPython 3.14.7, its bundled pip 26.2.1, and private
OpenSSL 4.0.2, Expat 2.8.4, libffi 3.8.0 and zlib 1.3.2 dependencies.
No base image or OpenSSL rebuild/benchmark was needed for installation.

## Device results

Before publication, the exported payload ran in an isolated chroot with the
image's musl loader. XML and SSL imports passed. Pip installed an offline wheel;
the module imported successfully and its generated console entry point executed.
The same installation and console entry point also passed with test data on the
device's actual exFAT `/data` filesystem. All temporary chroots, bind mounts,
archives and test data were removed afterward.

After publication, `nkos-addons install python` installed the signed repository
package through the normal manager. The installed package list retained `hello
1.0.0-r0` and added `python 3.14.7-r1`. After loading `/etc/profile`:

```text
python --version   -> Python 3.14.7
python3 --version  -> Python 3.14.7
pip --version     -> pip 26.2.1 (python 3.14)
pip3 --version    -> pip 26.2.1 (python 3.14)
```

At 17:47:54 UTC, an authenticated request to `/api/vm/script/run` returned
HTTP 200, application code 0 and `NKOS_PYTHON_API_OK 3.14.7 26.2.1` from a
temporary `.py` script importing pip and Expat. The script was removed.

The interpreter and bundled pip reside in rootfs under `/opt/nkos/addons/python`.
Default pip-installed modules use `/data/python/lib/python3.14/site-packages`;
their console scripts use `/data/python/bin`. Pip's root-user and script-PATH
warnings were visible during the test; no system-file conflict occurred.

Installation did not reboot the device or replace its server, web application,
FIT or complete rootfs image. Python remains an optional APK rather than a
base-image component. This acceptance covers the tested interpreter/pip paths,
not every optional standard-library extension or arbitrary third-party native
extension. Existing beta-10 package-manager syntax remains unchanged.
