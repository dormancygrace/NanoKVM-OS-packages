#!/usr/bin/env python3
"""Export source-built CPython and its bundled pip as a private-library addon."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--buildroot-output', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    br, out = args.buildroot_output.resolve(), args.out.resolve()
    config = (br / '.config').read_text()
    for flag in ('BR2_OPTIMIZE_2=y', 'BR2_TOOLCHAIN_BUILDROOT_MUSL=y', 'BR2_PACKAGE_PYTHON3_SSL=y', 'BR2_PACKAGE_PYTHON3_ZLIB=y', 'BR2_PACKAGE_PYTHON3_PYEXPAT=y'):
        if flag not in config.splitlines():
            parser.error('Missing source-build requirement: ' + flag)
    if out.exists():
        parser.error('Output must not exist')
    target = br / 'target'
    build = br / 'build/python3-3.14.7'
    root = out / 'python'
    patchelf = br / 'host/bin/patchelf'
    if not patchelf.is_file():
        patchelf = Path(shutil.which('patchelf') or '/missing-patchelf')
    strip = br / 'host/bin/riscv64-buildroot-linux-musl-strip'
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()

    def copy(source, dest):
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, dest)  # Expand Buildroot aliases: addon links forbidden.

    def command(*argv):
        return subprocess.check_output(list(map(str, argv)), text=True).strip()

    def elf(path):
        with path.open('rb') as stream:
            return stream.read(4) == b'\x7fELF'

    copy(target / 'usr/bin/python3', root / 'usr/bin/python3.14')
    stdlib = target / 'usr/lib/python3.14'
    for source in stdlib.rglob('*'):
        relative = source.relative_to(stdlib)
        if source.is_file() and 'site-packages' not in relative.parts:
            copy(source, root / 'usr/lib/python3.14' / relative)
    # Use the pip wheel bundled in this exact CPython source, not get-pip/latest.
    wheels = list((build / 'Lib/ensurepip/_bundled').glob('pip-*-py3-none-any.whl'))
    if len(wheels) != 1:
        raise RuntimeError('Expected exactly one bundled pip wheel')
    wheel = wheels[0]
    site_packages = root / 'usr/lib/python3.14/site-packages'
    site_packages.mkdir(parents=True)
    with zipfile.ZipFile(wheel) as archive:
        for name in archive.namelist():
            dest = (site_packages / name).resolve()
            if not dest.is_relative_to(site_packages.resolve()):
                raise RuntimeError('Unsafe wheel path')
        archive.extractall(site_packages)
    # Direct shebang invocations must also find persistent user-installed modules.
    copy(Path(__file__).resolve().parents[1] / 'recipes/nkos-addon-python/runtime/sitecustomize.py',
         site_packages / 'sitecustomize.py')
    dependencies = set()
    pending = [path for path in root.rglob('*') if path.is_file() and elf(path)]
    seen = set()
    while pending:
        path = pending.pop()
        if path in seen:
            continue
        seen.add(path)
        header = command('readelf', '-h', path)
        if 'RISC-V' not in header or 'ELF64' not in header:
            raise RuntimeError('Wrong target ELF: ' + str(path))
        for name in command(patchelf, '--print-needed', path).splitlines():
            if name == 'libc.so':
                continue
            dependencies.add(name)
            dest = root / 'lib' / name
            if not dest.exists():
                source = next((target / folder / name for folder in ('usr/lib', 'lib')
                               if (target / folder / name).is_file()), None)
                if source is None:
                    raise RuntimeError('Missing private dependency: ' + name)
                copy(source, dest)
                pending.append(dest)
        subprocess.run([str(patchelf), '--set-rpath', '/opt/nkos/addons/python/lib', str(path)], check=True)
        subprocess.run([str(strip), '--strip-debug', str(path)], check=True)
    # Include the corresponding source licenses, including pip's vendored notices.
    for owner in ('python3-3.14.7', 'libopenssl-4.0.2', 'libffi-3.8.0', 'libzlib-1.3.2', 'expat-2.8.4'):
        for pattern in ('LICENSE*', 'LICENCE*', 'COPYING*', 'NOTICE*'):
            for source in (br / 'build' / owner).glob(pattern):
                if source.is_file():
                    copy(source, root / 'licenses' / owner / source.name)
    metadata = {'buildroot_package': 'python3', 'source_version': '3.14.7',
                'pip_version': wheel.name.split('-')[1], 'pip_wheel_sha256': sha(wheel),
                'license': 'Python-2.0, MIT, Apache-2.0, Zlib',
                'bundled_libraries': sorted(dependencies),
                'buildroot_config_sha256': sha(br / '.config'),
                'ssl_source_sha256': sha(build / 'Modules/_ssl.c'),
                'source_python_sha256': sha(target / 'usr/bin/python3'),
                'optimization': '-O2'}
    (root / 'build-provenance.json').write_text(json.dumps(metadata, indent=2)+'\n')
    records = {str(p.relative_to(out)): sha(p) for p in sorted(out.rglob('*')) if p.is_file()}
    (out / 'input.json').write_text(json.dumps({'schema': 1, 'packages': {'python': metadata}, 'files': records}, indent=2)+'\n')
    print(json.dumps({'files': len(records), 'bytes': sum(p.stat().st_size for p in root.rglob('*') if p.is_file()), **metadata}, indent=2))


if __name__ == '__main__':
    main()
