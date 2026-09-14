# Python addon input

The package imports CPython 3.14.7 built by NanoKVM's GCC 16.2/musl toolchain
with `-O2`, SSL, Unicode data, zlib and Expat/XML. Python is not selected in the base image.
Use a separate optional-components Buildroot output for future rebuilds.

Required config fragment (in addition to the existing NanoKVM optional-tools
toolchain/source pins):

```text
BR2_PACKAGE_PYTHON3=y
BR2_PACKAGE_PYTHON3_SSL=y
BR2_PACKAGE_PYTHON3_UNICODEDATA=y
BR2_PACKAGE_PYTHON3_ZLIB=y
BR2_PACKAGE_PYTHON3_PYEXPAT=y
```

Add this recipe's `patches/` directory to `BR2_GLOBAL_PATCH_DIR` before rebuilding
Python. Its narrow `_ssl.c` change disables removed OpenSSL 4 fixed-version
method entry points, leaving generic TLS/client/server methods available. The
source-built input retains the accepted OpenSSL 4.0.2 and zlib 1.3.2 libraries;
this is not an OpenSSL upgrade or benchmark.

Run Buildroot with a clean POSIX PATH. Rebuild `python3-dirclean` then `python3`
after changing its patches/configuration. Export without modifying that output:

```sh
python3 scripts/export-python-package.py \
  --buildroot-output /absolute/optional-output --out /new/python-input
```

The exporter takes the pip wheel bundled in this exact CPython source (26.2.1),
preserves its vendored notices, and bundles the private ELF dependency closure.
It expands aliases, fixes every ELF RUNPATH and records all hashes. The package
adds small `python`/`python3` and `pip`/`pip3` wrappers; there is only one native
interpreter. `NKOS_PYTHON_INPUT` selects this independent input in recipe builds.

The accompanying input-source archive preserves the original CPython, OpenSSL,
libffi, zlib and Expat archives, Buildroot configuration, and applied SSL patch. Binary
inputs and their source materials are published together and pinned in
`versions.env`; changing package content requires increasing `pkgrel`.

Default pip installations use persistent `/data/python`. The interpreter's
private `sitecustomize` applies this default only outside virtual environments
and when the user site is enabled; isolated/no-user-site Python modes retain
their normal behavior. Explicit Python/pip environment settings still override
the defaults. APK owns the interpreter and bundled pip, not user-installed
modules. Python minor-version changes require reinstalling incompatible user
modules into the new version's site directory.
