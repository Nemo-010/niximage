#!/bin/sh
#
# Build AppImages out of a synthetic Nix closure and check that they work on a
# machine that has no /nix/store at all, which is the whole point of the
# exercise. The closure is fake, but it is fake in the ways that matter: the
# binaries have the Nix dynamic linker, an rpath into the store, store paths
# compiled in as data, dlopen by absolute store path, children exec'd by
# absolute store path, a script with a store shebang and store symlinks.
#
# Run it with no arguments. KEEP=1 keeps the AppDir for inspection.

set -eu

TESTDIR=${TESTDIR:-$(cd "$(dirname "$0")" && pwd)}
ROOT=${ROOT:-$(cd "$TESTDIR/.." && pwd)}
WORK=$TESTDIR/tmp
KEEP=${KEEP:-0}
SIZES=

export TESTDIR

_fail() {
	echo "FAIL: $*" >&2
	exit 1
}

_check() {
	grep -qF "$1" "$OUTPUT" || _fail "expected '$1' in the output of the AppImage"
}

# the design only means anything if the store is really absent
if [ -e /nix/store ]; then
	_fail "this test has to run on a machine without /nix/store"
fi

for cmd in patchelf cc wget python3 sha256sum; do
	command -v "$cmd" >/dev/null || _fail "missing '$cmd'"
done

[ -f "$WORK/closure.txt" ] || "$TESTDIR/make-closure.sh"

# the store path of the test package, as the fake nix build would print it
HELLO=$(cat "$WORK/app.txt")
HELLO=${HELLO#/nix/store/}

# _package <main binary> <AppImage name>
_package() {
	echo "======================================================================"
	echo "Packaging the synthetic closure, entry point '$1'"
	echo "======================================================================"

	rm -rf "$ROOT/AppDir" "$ROOT/dist" "$ROOT/niximage-work"

	PATH="$TESTDIR/bin:$PATH" \
	STORE_ROOT="$WORK/store" \
	APP_REF=nixpkgs#hello \
	APPNAME=hello \
	MAIN_BIN="$1" \
	OUTNAME="$2" \
	"$ROOT/niximage.sh"

	APPIMAGE=$(ls "$ROOT"/dist/*.AppImage 2>/dev/null | head -n 1 || :)
	[ -n "$APPIMAGE" ] || _fail "no AppImage was produced"
	[ -x "$APPIMAGE" ] || _fail "$APPIMAGE is not executable"
	SIZES="$SIZES$1: $(du -h "$APPIMAGE" | cut -f1) AppImage, \
$(du -sh "$ROOT/AppDir" | cut -f1) AppDir
"
}

# _run <AppImage> <extraction directory> : the extraction directory is kept,
# so what the AppImage created at runtime can be looked at afterwards
_run() {
	echo "======================================================================"
	echo "Running $1 without /nix/store"
	echo "======================================================================"

	OUTPUT=$WORK/output-$(basename "$2").txt
	RUN_APPDIR=$2
	rm -rf "$RUN_APPDIR"
	env -i PATH=/usr/bin:/bin HOME="${HOME:-/tmp}" \
		APPIMAGE_EXTRACT_AND_RUN=1 \
		APPIMAGE_TARGET_DIR="$RUN_APPDIR" \
		"$1" > "$OUTPUT" 2>&1 || {
		echo "---- output ----"
		cat "$OUTPUT"
		_fail "$1 exited with an error"
	}
	cat "$OUTPUT"
}

# ---------------------------------------------------------------- ELF entry point

_package hello hello-x86_64.AppImage
_run "$APPIMAGE" "$WORK/test-app"

# every line below is produced by a different mechanism:
#   EXE      /proc/self/exe is the launcher, not the dynamic linker
#   DATA     a store path compiled into the binary as data
#   REALPATH the same file, resolved: it lives inside the AppImage
#   DLOPEN   a shared library dlopened by its absolute store path
#   LIBHELLO the constructor of that library
#   HELPER   a child process exec'd by its absolute store path
#   SCRIPT   a script whose shebang is a store interpreter
_check "DATA: niximage test data"
_check "DLOPEN: ok"
_check "LIBHELLO: loaded"
_check "HELPER: ran"
_check "HELPER: exit 0"
_check "SCRIPT: ran with bash"
_check "SCRIPT: exit 0"

EXE=$(awk '/^EXE:/{print $2}' "$OUTPUT")
case "$EXE" in
	*/bin/hello) ;;
	*) _fail "the application was not launched through sharun (EXE='$EXE')" ;;
esac
case "$EXE" in
	*ld-linux*) _fail "the process was started by the dynamic linker (EXE='$EXE')" ;;
esac

REALPATH=$(awk '/^REALPATH:/{print $2}' "$OUTPUT")
case "$REALPATH" in
	/nix/store/*) _fail "the data file was read from a host /nix/store" ;;
	"$RUN_APPDIR"/nix/store/*|"$RUN_APPDIR"/*/nix/store/*) ;;
	*) _fail "the data file was not read from the bundled closure ('$REALPATH')" ;;
esac

[ -f "$ROOT/AppDir/nix/store/$HELLO/share/hello/data.txt" ] \
	|| _fail "the closure is not inside the AppDir"

# the AppImage has to carry its own libc and dynamic linker
[ -f "$ROOT/AppDir/lib/libc.so.6" ] || _fail "no libc in the AppImage"
[ -f "$ROOT/AppDir/lib/ld-linux-x86-64.so.2" ] || _fail "no dynamic linker in the AppImage"

# nothing in the AppImage may point at the tree it was built in
LEAKED=$(grep -rlF "$ROOT/niximage-work" "$ROOT/AppDir" 2>/dev/null | head -n 3 || :)
[ -z "$LEAKED" ] || _fail "files in the AppImage point at the build tree: $LEAKED"

# control: the same application, before relocation, cannot run here
if "$WORK/store/$HELLO/bin/hello" > "$WORK/unrelocated.txt" 2>&1; then
	_fail "the unrelocated binary ran, so this test proves nothing"
fi
echo "control: the unrelocated binary fails as expected ($(head -n 1 "$WORK/unrelocated.txt"))"

# ------------------------------------------------------------- script entry point

# Nix packages often have a wrapper script as their entry point (that is what
# makeWrapper produces). quick-sharun rewrites the shebang of such a script to
# '#!/usr/bin/env <interpreter>', so the interpreter has to be in the AppImage.
_package hello-script hello-script-x86_64.AppImage
_run "$APPIMAGE" "$WORK/test-app-script"

_check "SCRIPT: ran with bash"
[ -f "$RUN_APPDIR/bin/bash" ] || _fail "the interpreter was not deployed to bin/"
[ -f "$RUN_APPDIR/shared/bin/bash" ] || _fail "the interpreter itself is not in the AppImage"
[ "$(head -n 1 "$RUN_APPDIR/bin/hello-script")" = '#!/usr/bin/env bash' ] \
	|| _fail "the shebang of the entry point script was not rewritten as expected"

# ------------------------------------------------------------- the store prefix

STOREMAP=$(grep -oE '/tmp/[a-z0-9]{5}' "$ROOT/AppDir/bin/00-nix-store.hook" \
	| head -n 1 || :)
case "$STOREMAP" in
	/tmp/?????) ;;
	*) _fail "could not read the relocated store prefix from the hook" ;;
esac
[ -d "$STOREMAP" ] || _fail "the hook did not create the relocated prefix"

HELLO_SHARE=$STOREMAP/$HELLO
RESOLVED=$(readlink -f "$HELLO_SHARE")
case "$RESOLVED" in
	"$RUN_APPDIR"*) ;;
	*) _fail "$STOREMAP/$HELLO did not resolve into the running AppImage" ;;
esac
echo "runtime: $STOREMAP/\${store path} -> $RESOLVED"

echo "======================================================================"
echo "Everything passed"
printf '%s' "$SIZES"
echo "======================================================================"

if [ "$KEEP" != 1 ]; then
	rm -rf "$ROOT/AppDir" "$ROOT/niximage-work"
fi
