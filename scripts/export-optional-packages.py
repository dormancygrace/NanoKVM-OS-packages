#!/usr/bin/env python3
"""Export O2 Buildroot packages and their private ELF closure for APK recipes.

The input is a source-built NanoKVM Buildroot output, never an Alpine rootfs.
mc-prefix is a DESTDIR rebuilt with prefix=/opt/nkos/addons/mc/usr,
sysconfdir=/opt/nkos/addons/mc/etc, libexecdir=/opt/nkos/addons/mc/usr/libexec.
"""
import argparse, hashlib, json, os, re, shutil, subprocess
from pathlib import Path

PACKAGES = {
 'mc': ('mc','4.8.33','GPL-3.0+'),
 'superfile': ('nkos-superfile','1.6.0','MIT'),
 'nano': ('nano','9.2','GPL-3.0+'),
 'htop': ('htop','3.5.3','GPL-2.0'),
 'tcpdump': ('tcpdump','4.99.6','BSD-3-Clause'),
 'ethtool': ('ethtool','7.1','GPL-2.0'),
 'bluez5-utils': ('bluez5_utils','5.87','GPL-2.0+, LGPL-2.1+'),
}

def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--buildroot-output',type=Path,required=True)
 p.add_argument('--mc-prefix',type=Path,required=True)
 p.add_argument('--out',type=Path,required=True)
 a=p.parse_args(); br=a.buildroot_output.resolve(); target=br/'target'; out=a.out.resolve()
 if out.exists(): p.error('Output must not exist')
 config=(br/'.config').read_text()
 if 'BR2_OPTIMIZE_2=y' not in config or 'BR2_TOOLCHAIN_BUILDROOT_MUSL=y' not in config: p.error('Expected O2/musl source build')
 patchelf=br/'host/bin/patchelf'; strip=br/'host/bin/riscv64-buildroot-linux-musl-strip'
 owners={}
 for line in (br/'build/packages-file-list.txt').read_text().splitlines():
  owner,path=line.split(',',1); owners.setdefault(owner,[]).append(path.removeprefix('./'))
 def copy(src,dst):
  # Buildroot aliases are expanded to regular files: APK payload forbids links.
  if not src.is_file(): return
  dst.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(src,dst)
 def elf(path):
  with path.open('rb') as f: return f.read(4)==b'\x7fELF'
 def command(*args): return subprocess.check_output([str(x) for x in args],text=True).strip()
 def library(name):
  for directory in ('usr/lib','lib'):
   src=target/directory/name
   if src.is_file(): return src
  raise RuntimeError('Missing target library '+name)
 metadata={}
 for id,(owner,version,license) in PACKAGES.items():
  root=out/id; root.mkdir(parents=True)
  if id=='mc':
   prefix=a.mc_prefix/'opt/nkos/addons/mc'
   if not (prefix/'usr/bin/mc').is_file(): raise RuntimeError('Missing relocated mc')
   for src in prefix.rglob('*'):
    if src.is_file(): copy(src,root/src.relative_to(prefix))
  else:
   for rel in owners[owner]:
    if rel.startswith(('etc/init.d/','usr/include/','usr/lib/pkgconfig/')) or rel.endswith(('.la','.a')): continue
    copy(target/rel,root/rel)
  if id=='bluez5-utils':
   # BlueZ is the only base consumer of D-Bus in this image configuration.
   # Package its own bus instead of retaining a boot-time base daemon.
   for name in ('dbus-daemon','dbus-send'):
    copy(target/'usr/bin'/name,root/'usr/bin'/name)
  if id=='superfile':
   # superfile is an alias of spf; keep one 20 MB Go executable.
   (root/'usr/bin/superfile').unlink(missing_ok=True)
  # The same TERM database travels with terminal tools; no dependency on tmux.
  if id in ('mc','nano','htop'):
   for src in (target/'usr/share/terminfo').rglob('*'):
    if src.is_file(): copy(src,root/'usr/share/terminfo'/src.relative_to(target/'usr/share/terminfo'))
  pending=[x for x in root.rglob('*') if x.is_file() and elf(x)]
  seen=set(); dependency_names=set()
  while pending:
   src=pending.pop()
   if src in seen: continue
   seen.add(src)
   header=command('readelf','-h',src)
   if 'RISC-V' not in header or 'ELF64' not in header: raise RuntimeError('Wrong target ELF '+str(src))
   dynamic='(NEEDED)' in command('readelf','-d',src)
   if not dynamic: continue
   for name in command(patchelf,'--print-needed',src).splitlines():
    if name=='libc.so': continue
    dependency_names.add(name)
    dest=root/'lib'/name
    if not dest.exists(): copy(library(name),dest); pending.append(dest)
   subprocess.run([str(patchelf),'--set-rpath',f'/opt/nkos/addons/{id}/lib',str(src)],check=True)
  for src in seen:
   subprocess.run([str(strip),'--strip-debug',str(src)],check=True)
  # License texts for the main package and all bundled library owners.
  license_owners={owner}
  for name in dependency_names:
   resolved=library(name).resolve()
   for pkg,paths in owners.items():
    if any((target/path).resolve()==resolved for path in paths if '/lib' in path): license_owners.add(pkg)
  for pkg in license_owners:
   for build in (br/'build').glob(pkg+'-*'):
    if not build.is_dir(): continue
    for pattern in ('COPYING*','LICENSE*','LICENCE*','NOTICE*'):
     for src in build.glob(pattern):
      if src.is_file(): copy(src,root/'licenses'/pkg/src.name)
  bin=root/'bin';bin.mkdir(exist_ok=True)
  for directory in ('usr/bin','usr/sbin'):
   for src in (root/directory).glob('*'):
    if not src.is_file() or not os.access(src,os.X_OK): continue
    wrapper=bin/src.name
    setup=f'root=/opt/nkos/addons/{id}\nexport TERMINFO_DIRS="$root/usr/share/terminfo:/usr/share/terminfo"\n'
    if id in ('mc','htop','superfile'):
     setup+=f'export XDG_CONFIG_HOME=/etc/kvm/{id}\nmkdir -p "$XDG_CONFIG_HOME"\n'
    if id=='superfile':
     setup+='export PATH="/opt/nkos/addons/nano/bin:$PATH"\n'
    if id=='bluez5-utils':
     setup+='export DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/nkos-addon/bluez5-utils/bus/socket\n'
    if id=='nano':
     setup+='mkdir -p /etc/kvm/nano\nif [ ! -e /etc/kvm/nano/nanorc ]; then\n  printf \'include "%s/usr/share/nano/*.nanorc"\\n\' "$root" > /etc/kvm/nano/nanorc\nfi\n'
    args='--rcfile=/etc/kvm/nano/nanorc ' if id=='nano' else ''
    wrapper.write_text('#!/bin/sh\nset -eu\n'+setup+f'exec "$root/{directory}/{src.name}" '+args+'"$@"\n');wrapper.chmod(0o755)
  if id=='bluez5-utils':
   (root/'bus.conf').write_text('''<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
 <type>system</type>
 <listen>unix:path=/run/nkos-addon/bluez5-utils/bus/socket</listen>
 <auth>EXTERNAL</auth>
 <policy user="root"><allow own="*"/><allow send_destination="*"/><allow receive_sender="*"/></policy>
</busconfig>
''')
   service=bin/'bluetooth-service'
   service.write_text('''#!/bin/sh
set -eu
root=/opt/nkos/addons/bluez5-utils
export CONFIGURATION_DIRECTORY=/etc/kvm/bluez5-utils
# Keep bond keys on the root filesystem with Unix permissions, not exFAT.
export STATE_DIRECTORY=/etc/kvm/bluez5-utils/state
umask 077
mkdir -p "$CONFIGURATION_DIRECTORY" "$STATE_DIRECTORY"
for name in main.conf input.conf network.conf; do
  if [ ! -e "$CONFIGURATION_DIRECTORY/$name" ]; then
    cp "$root/etc/bluetooth/$name" "$CONFIGURATION_DIRECTORY/$name"
  fi
done
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/nkos-addon/bluez5-utils/bus/socket
mkdir -p /run/nkos-addon/bluez5-utils/bus
bus_pid= bluetooth_pid=
cleanup() {
  trap - EXIT INT TERM
  [ -z "$bluetooth_pid" ] || kill "$bluetooth_pid" 2>/dev/null || :
  [ -z "$bus_pid" ] || kill "$bus_pid" 2>/dev/null || :
  wait 2>/dev/null || :
}
trap cleanup EXIT
trap 'exit 0' INT TERM
"$root/usr/bin/dbus-daemon" --nofork --config-file="$root/bus.conf" &
bus_pid=$!
n=0
while [ ! -S /run/nkos-addon/bluez5-utils/bus/socket ]; do
  kill -0 "$bus_pid" 2>/dev/null || exit 1
  n=$((n+1)); [ "$n" -lt 50 ] || exit 1
  sleep .1
done
"$root/usr/libexec/bluetooth/bluetoothd" --nodetach &
bluetooth_pid=$!
wait "$bluetooth_pid"
''');service.chmod(0o755)
  if id=='superfile':
   (bin/'superfile').write_text('#!/bin/sh\nexec /opt/nkos/addons/superfile/bin/spf "$@"\n');(bin/'superfile').chmod(0o755)
  metadata[id]={'buildroot_package':owner,'source_version':version,'license':license,'bundled_libraries':sorted(dependency_names),'license_owners':sorted(license_owners)}
  (root/'build-provenance.json').write_text(json.dumps(metadata[id],indent=2)+'\n')
 records={str(x.relative_to(out)):hashlib.sha256(x.read_bytes()).hexdigest() for x in sorted(out.rglob('*')) if x.is_file()}
 (out/'input.json').write_text(json.dumps({'schema':1,'packages':metadata,'files':records},indent=2)+'\n')
 print(json.dumps({id:sum(x.stat().st_size for x in (out/id).rglob('*') if x.is_file()) for id in PACKAGES},indent=2))

if __name__=='__main__': main()
