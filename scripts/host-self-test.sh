#!/bin/sh
# Host-only APK/signature, resolver and namespace gate.  All keys are temporary.
set -eu

apk=${NKOS_HOST_APK:-}
while [ "$#" -gt 0 ]; do
	case $1 in
		--apk) [ "$#" -ge 2 ] || { echo 'usage: host-self-test.sh --apk APK' >&2; exit 2; }; apk=$2; shift 2;;
		*) echo 'usage: host-self-test.sh --apk APK' >&2; exit 2;;
	esac
done
[ -n "$apk" ] && [ -x "$apk" ] || { echo 'host-self-test: pass --apk from build-apk-tools.sh' >&2; exit 127; }
command -v openssl >/dev/null 2>&1 || { echo 'host-self-test: openssl is required' >&2; exit 127; }
command -v python3 >/dev/null 2>&1 || { echo 'host-self-test: python3 is required' >&2; exit 127; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/nkos-apk-self-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/keys" "$tmp/payload/addons/demo/bin" "$tmp/repository/riscv64"
# The fixture key is disposable; production trust material is never generated
# or read by this test.  The signing implementation remains algorithm-agile.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$tmp/signing.pem" >/dev/null 2>&1
openssl pkey -in "$tmp/signing.pem" -pubout -out "$tmp/keys/nkos-selftest-rsa4096.pem" >/dev/null 2>&1
cat > "$tmp/payload/addons/demo/bin/demo" <<'EOF'
#!/bin/sh
printf '%s\n' 'fixture addon'
EOF
chmod 0755 "$tmp/payload/addons/demo/bin/demo"


# Keep the package revision independent from the upstream version.  apk's
# native comparator must order r1 before r2; lexical shell sorting is not a
# valid package update check.
[ "$("$apk" version --test 1.0.0-r1 1.0.0-r2)" = "<" ]
[ "$("$apk" version --test 1.0.0-r2 1.0.0-r1)" = ">" ]

"$apk" --sign-key "$tmp/signing.pem" mkpkg --compat 3.0.8 \
	--files "$tmp/payload" --output "$tmp/repository/riscv64/nkos-addon-demo-1.0.0-r0.apk" \
	--info 'name:nkos-addon-demo' --info 'version:1.0.0-r0' --info 'arch:riscv64' \
	--info 'description:isolated host fixture' --info 'license:MIT' \
	--info 'depends:nkos-base-abi=1.0.0 nkos-server-api=1 nkos-feature-shell=1 nkos-feature-static-riscv64=1' \
	--info 'tags:nkos-addon'
"$apk" --keys-dir "$tmp/keys" verify "$tmp/repository/riscv64/nkos-addon-demo-1.0.0-r0.apk"
"$apk" --keys-dir "$tmp/keys" --sign-key "$tmp/signing.pem" mkndx \
	--output "$tmp/repository/riscv64/Packages.adb" \
	--pkgname-spec '${arch}/${name}-${version}.apk' \
	"$tmp/repository/riscv64/nkos-addon-demo-1.0.0-r0.apk"
"$apk" --keys-dir "$tmp/keys" verify "$tmp/repository/riscv64/Packages.adb"

# Exercise the published v3 layout over HTTP. A local-file install would not
# detect a pkgname-spec that omits the architecture directory.
cat > "$tmp/http-server.py" <<'PY'
import http.server
import pathlib
import sys

root = sys.argv[1]
port_file = pathlib.Path(sys.argv[2])
handler = lambda *args, **kwargs: http.server.SimpleHTTPRequestHandler(
    *args, directory=root, **kwargs
)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
port_file.write_text(str(server.server_port), encoding="ascii")
server.serve_forever()
PY
python3 "$tmp/http-server.py" "$tmp/repository" "$tmp/http-port" \
	>"$tmp/http-server.log" 2>&1 &
http_server_pid=$!
trap 'kill "$http_server_pid" 2>/dev/null || true; wait "$http_server_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT HUP INT TERM
attempt=0
while [ ! -s "$tmp/http-port" ]; do
	attempt=$((attempt + 1))
	[ "$attempt" -lt 100 ] || { echo 'host-self-test: HTTP server did not start' >&2; exit 1; }
	sleep 0.05
done
http_root="$tmp/http-root"
mkdir -p "$http_root/etc/apk/keys"
printf '%s\n' riscv64 > "$http_root/etc/apk/arch"
printf 'v3 http://127.0.0.1:%s\n' "$(cat "$tmp/http-port")" > "$http_root/etc/apk/repositories"
cp "$tmp/keys/nkos-selftest-rsa4096.pem" "$http_root/etc/apk/keys/"
if [ "$(id -u)" -eq 0 ]; then
	http_user_mode=
else
	http_user_mode=--usermode
fi
for provider in nkos-base-abi=1.0.0 nkos-server-api=1 nkos-feature-shell=1 nkos-feature-static-riscv64=1; do
	"$apk" --root "$http_root" --root-tmpfs=no --no-network $http_user_mode add \
		--initdb --no-scripts --virtual "$provider"
done
"$apk" --root "$http_root" --root-tmpfs=no $http_user_mode update
"$apk" --root "$http_root" --root-tmpfs=no $http_user_mode add \
	--no-scripts nkos-addon-demo=1.0.0-r0
"$apk" --root "$http_root" --root-tmpfs=no --no-network info --installed nkos-addon-demo
[ -x "$http_root/addons/demo/bin/demo" ]

# Inspect the installed addon subtree after the native HTTP transaction. This
# exercises APKv3's archive extraction while preserving implicit directories.
python3 - "$http_root/addons" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for path in root.rglob("*"):
    relative = path.relative_to(root).as_posix()
    allowed = relative == "demo" or relative.startswith("demo/")
    if path.is_symlink() or not allowed:
        raise SystemExit(f"host-self-test: installed path escaped addon namespace: {relative}")
if not (root / "demo/bin/demo").is_file():
    raise SystemExit("host-self-test: fixture executable was not installed")
PY

# Build the image-only ABI records through native apk add --virtual.  No
# provider APKs or repository index entries are created.
image_root="$tmp/image-root"
mkdir -p "$image_root/etc/apk/keys"
printf '%s\n' riscv64 > "$image_root/etc/apk/arch"
: > "$image_root/etc/apk/repositories"
cp "$tmp/keys/nkos-selftest-rsa4096.pem" "$image_root/etc/apk/keys/"
if [ "$(id -u)" -eq 0 ]; then
	apk_user_mode=
else
	apk_user_mode=--usermode
fi
"$apk" --root "$image_root" --root-tmpfs=no --no-network $apk_user_mode add \
	--initdb --no-scripts --virtual nkos-base-abi=1.0.0
for provider in nkos-server-api=1 nkos-feature-shell=1 nkos-feature-static-riscv64=1; do
	"$apk" --root "$image_root" --root-tmpfs=no --no-network $apk_user_mode add \
		--no-scripts --virtual "$provider"
done
"$apk" --root "$image_root" --root-tmpfs=no --no-network add --no-scripts \
	"$tmp/repository/riscv64/nkos-addon-demo-1.0.0-r0.apk"
grep -Fx 'nkos-base-abi=1.0.0' "$image_root/etc/apk/world"
grep -Fx 'nkos-server-api=1' "$image_root/etc/apk/world"
grep -Fx 'nkos-feature-shell=1' "$image_root/etc/apk/world"
grep -Fx 'nkos-feature-static-riscv64=1' "$image_root/etc/apk/world"
"$apk" --root "$image_root" --root-tmpfs=no --no-network info --installed nkos-addon-demo
[ ! -e "$tmp/repository/riscv64/nkos-base-abi-1.0.0.apk" ]
[ ! -e "$image_root/addons/nkos-base-abi" ]
"$apk" --root "$image_root" --root-tmpfs=no --no-network del --no-scripts nkos-addon-demo
[ ! -e "$image_root/addons/demo" ]

# A signed r1 -> r2 transition is accepted by apk's resolver only when the
# package identity is unchanged and the native version ordering increases.
mkdir -p "$tmp/revision-payload/addons/revision/bin"
printf '%s\n' r1 > "$tmp/revision-payload/addons/revision/bin/revision"
for revision in r1 r2; do
	printf '%s\n' "$revision" > "$tmp/revision-payload/addons/revision/bin/revision"
	"$apk" --sign-key "$tmp/signing.pem" mkpkg --compat 3.0.8 \
		--files "$tmp/revision-payload" --output "$tmp/revision-$revision.apk" \
		--info 'name:nkos-addon-revision' --info "version:1.0.0-$revision" --info 'arch:riscv64' \
		--info 'description:signed revision fixture' --info 'license:MIT' \
		--info 'depends:nkos-base-abi=1.0.0 nkos-server-api=1 nkos-feature-shell=1' \
		--info 'tags:nkos-addon'
	"$apk" --keys-dir "$tmp/keys" verify "$tmp/revision-$revision.apk"
done
"$apk" --root "$image_root" --root-tmpfs=no --no-network add --no-scripts \
	"$tmp/revision-r1.apk"
"$apk" --root "$image_root" --root-tmpfs=no --no-network add --no-scripts --upgrade \
	"$tmp/revision-r2.apk"
installed_revision=$("$apk" --root "$image_root" --root-tmpfs=no --no-network -v info --installed nkos-addon-revision)
printf '%s\n' "$installed_revision" | grep -Fq '1.0.0-r2'
printf '%s\n' r2 | cmp -s - "$image_root/addons/revision/bin/revision"

# The fixture uses the currently authorized production-compatible key type,
# but the repository contract remains algorithm-agile: apk-tools decides which
# key formats it can sign and the isolated trust directory verifies the result.
# No global RSA-only or Ed25519-only policy is encoded here.

# Exercise the source validator's negative path without changing this checkout.
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
bad="$tmp/bad-repository"
mkdir -p "$bad/recipes/nkos-addon-bad/files/addons/bad" "$bad/recipes/nkos-addon-bad"
cp "$repo/recipes/nkos-addon-hello/manifest.json" "$bad/recipes/nkos-addon-bad/manifest.json"
sed -i 's/"id": "hello"/"id": "bad"/; s/nkos-addon-hello/nkos-addon-bad/g; s#addons/hello#addons/bad#g; s#/hello#/bad#g' "$bad/recipes/nkos-addon-bad/manifest.json"
printf '%s\n' evil > "$bad/recipes/nkos-addon-bad/files/etc-escape"
cp "$repo/recipes/nkos-addon-hello/build.sh" "$bad/recipes/nkos-addon-bad/build.sh"
if python3 "$repo/scripts/validate-repository.py" --root "$bad" --base-abi nkos-base-abi=1.0.0 --apk "$apk" >/dev/null 2>&1; then
	echo 'host-self-test: validator accepted an unsafe fixture' >&2
	exit 1
fi
echo 'host APK/signature/resolver/payload policy self-test passed (throwaway keys only)'
