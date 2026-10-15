#!/bin/sh
#
# NixImage - build a truly portable AppImage from a Nix package.
#
# Nix builds and pins the application and its complete closure, this script
# stages that closure into a /usr-like tree, relocates the Nix store prefix so
# that nothing needs /nix/store at runtime, and hands the result to
# pkgforge-dev's quick-sharun, which deploys the libraries and packages the
# AppImage with the sharun runtime.
#
#   APPNAME=hello APP_REF=nixpkgs#hello ./niximage.sh
#
# See README.md.

set -eu

ARCH=${ARCH:-$(uname -m)}
APPNAME=${APPNAME:-}
MAIN_BIN=${MAIN_BIN:-$APPNAME}
APP_REF=${APP_REF:-}
APP_STORE_PATH=${APP_STORE_PATH:-}
APPDIR=${APPDIR:-$PWD/AppDir}
OUTPATH=${OUTPATH:-$PWD/dist}
OUTNAME=${OUTNAME:-${APPNAME}-${ARCH}.AppImage}
WORK=${WORK:-$PWD/niximage-work}
DESKTOP=${DESKTOP:-}
ICON=${ICON:-}

# the store prefix that Nix bakes into every binary, and where the store
# actually lives on this machine (STORE_ROOT only needs changing for a store
# that is not mounted at /nix/store, such as the test suite's fake one)
STORE_PREFIX=${STORE_PREFIX:-/nix/store}
STORE_ROOT=${STORE_ROOT:-$STORE_PREFIX}
CLOSURE_FILE=${CLOSURE_FILE:-}

QUICK_SHARUN=${QUICK_SHARUN:-$WORK/quick-sharun}
QUICK_SHARUN_LINK=${QUICK_SHARUN_LINK:-https://raw.githubusercontent.com/pkgforge-dev/Anylinux-AppImages/b72f0c4fdffbb6b80c034ad31e7dbf842418c409/useful-tools/quick-sharun.sh}

# everything a Nix package may install into, which is merged into the
# /usr-like tree that quick-sharun is given
SUBDIRS="bin sbin lib lib64 libexec share etc include"

_echo() {
	printf '\033[1;92m%s\033[0m\n' " $*"
}

_err_msg() {
	>&2 printf '\033[1;31m%s\033[0m\n' " $*"
}

_is_cmd() {
	for cmd do
		command -v "$cmd" 1>/dev/null || return 1
	done
	return 0
}

_abs() {
	case "$1" in
		/*) printf '%s\n' "$1" ;;
		*)  printf '%s\n' "$PWD/$1" ;;
	esac
}

_cleanup() {
	# the build time store view must never leak into the AppImage
	if [ -n "${STOREMAP:-}" ] && [ -e "$STOREMAP" ]; then
		rm -rf "$STOREMAP"
	fi
}

# ------------ the application, straight from Nix ------------

_nix() {
	nix --extra-experimental-features 'nix-command flakes' "$@"
}

# build the package and print its store path
_store_path() {
	if [ -n "$APP_STORE_PATH" ]; then
		printf '%s\n' "$APP_STORE_PATH"
	elif [ -n "$APP_REF" ]; then
		_nix build --no-link --print-out-paths "$APP_REF"
	else
		_err_msg "ERROR: set APP_REF (example: APP_REF=nixpkgs#hello)"
		_err_msg "or APP_STORE_PATH to a package that is already built"
		exit 1
	fi
}

# every store path the package needs at runtime: 'the application, and
# everything it depends on except the kernel'
_closure() {
	if [ -n "$CLOSURE_FILE" ]; then
		cat "$CLOSURE_FILE"
	elif _is_cmd nix-store; then
		nix-store -qR "$1"
	else
		_nix path-info -r "$1"
	fi
}

# ------------ relocation ------------

# Nix binaries carry absolute store paths: the ELF interpreter, the rpath,
# shebangs, dlopen paths, data dirs, wrapper scripts, symlink targets. We
# cannot make them relative, but the prefix /nix/store is exactly as long as
# the /tmp/xxxxx name we replace it with, so a plain byte for byte
# substitution in the whole closure is safe (same trick quick-sharun uses for
# hardcoded /usr paths). The replacement is a symlink to the copy of the
# closure that ships inside the AppImage.
_relocate_files() {
	list=$(mktemp)
	find "$STORE_STAGE" -type f \
		-exec grep -lF --binary-files=text -- "$STORE_PREFIX" {} + > "$list" || :
	while IFS= read -r f; do
		sed -i "s|$STORE_PREFIX|$STOREMAP|g" "$f"
	done < "$list"
	rm -f "$list"
}

_relocate_symlinks() {
	find "$STORE_STAGE" -type l | while IFS= read -r l; do
		t=$(readlink "$l") || continue
		case "$t" in
			"$STORE_PREFIX"/*)
				ln -sfn "$STOREMAP${t#"$STORE_PREFIX"}" "$l"
				;;
		esac
	done
}

# symlinks that point into the store (alsa and friends ship data that way,
# and every soname is one) cannot be dereferenced by a single 'cp -r -L'
# without that failing for the whole subtree, so they are replaced by what
# they point at afterwards
_resolve_store_symlinks() {
	find "$1" -type l | while IFS= read -r l; do
		t=$(readlink "$l") || continue
		case "$t" in
			"$STOREMAP"/*) ;;
			*) continue ;;
		esac
		[ -e "$t" ] || continue
		rm -f "$l"
		cp -rL "$t" "$l" 2>/dev/null || :
	done
}

# merge the closure into a single /usr-like prefix, the way an FHS
# distribution would have installed it. The store copy has to be reachable
# through the relocated prefix first, because that is how the absolute store
# symlinks inside the closure resolve.
_stage_fhs() {
	for p in $CLOSURE; do
		rel=${p#"$STORE_PREFIX"/}
		for sub in $SUBDIRS; do
			[ -d "$STORE_STAGE/$rel/$sub" ] || continue
			mkdir -p "$FHS_STAGE/$sub"
			# hardlink real files (cheap, and they end up flat), never
			# clobber: the package the closure starts from comes first
			# and has to win over its dependencies
			cp -rn "$STORE_STAGE/$rel/$sub"/. "$FHS_STAGE/$sub"/ 2>/dev/null || :
		done
	done
	_resolve_store_symlinks "$FHS_STAGE"
}

_rewrite_desktop_exec() {
	# a .desktop Exec= that points into the store is useless inside the
	# AppImage, AppRun picks the binary by name anyway
	for f in "$FHS_STAGE"/share/applications/*.desktop; do
		[ -f "$f" ] || continue
		sed -i -e "s|^\(Exec\)=$STOREMAP/[^ ]*/bin/|\1=|" "$f"
	done
}

# ------------ quick-sharun ------------

# Point the relocated store prefix at a tree for the duration of the build.
# quick-sharun runs the staged binaries to find what they dlopen and resolves
# what they reference back to a file on disk, so pointing the prefix at the
# merged /usr view is what makes every deployed library land in the flat
# layout the AppImage uses. The AppImage itself gets a per package view of
# the closure, created by the hook at runtime.
_relocated_view() {
	rm -rf "$STOREMAP"
	mkdir -p "$STOREMAP"
	for p in $CLOSURE; do
		rel=${p#"$STORE_PREFIX"/}
		ln -sfn "$1" "$STOREMAP/$rel"
	done
}

# make the relocated prefix resolve to the copy of the closure in the AppDir
_add_store_hook() {
	mkdir -p "$APPDIR/bin"
	cat <<-EOF > "$APPDIR/bin/00-nix-store.hook"
	# generated by niximage.sh: point the relocated store prefix at the copy
	# of the Nix closure that ships inside this AppImage
	if [ -n "\$APPDIR" ] && [ -d "\$APPDIR/nix/store" ]; then
	        [ ! -L "$STOREMAP" ] || rm -f "$STOREMAP"
	        mkdir -p "$STOREMAP" 2>/dev/null || :
	        for _p in "\$APPDIR"/nix/store/*; do
	                [ -e "\$_p" ] || continue
	                LC_ALL=C ln -sfn "\$_p" "$STOREMAP/\${_p##*/}" 2>/dev/null || :
	        done
	fi
	EOF
}

# quick-sharun rewrites the shebang of every script it deploys to
# '#!/usr/bin/env <interpreter>', which throws away the arguments the
# original had: a Nix wrapper starts with '#!/nix/store/.../bin/bash -e', and
# '#!/usr/bin/env bash -e' cannot be executed at all, because env takes
# 'bash -e' as a single command name. The interpreter is inside the AppImage
# either way, so point the shebang at the closure's own copy of it, which is
# a path that is valid at runtime and keeps the arguments.
_fix_script_shebangs() {
	for d in "$APPDIR/bin" "$APPDIR/shared/bin"; do
		[ -d "$d" ] || continue
		for f in "$d"/*; do
			[ -f "$f" ] || continue
			case "$f" in *.hook|*/AppRun*|*/sharun) continue ;; esac
			[ "$(head -c 2 "$f" 2>/dev/null || :)" = '#!' ] || continue
			line=$(sed -n '1p' "$f")
			case "$line" in
				'#!'*'env '*)
					interp=$(printf '%s\n' "$line" | awk '{ print $2 }')
					args=$(printf '%s\n' "$line" | awk '\
						{ for (i = 3; i <= NF; i++) printf "%s%s", (i > 3 ? " " : ""), $i }')
					[ -n "$args" ] || continue
					;;
				*) continue ;;
			esac
			[ -n "$interp" ] || continue
			found=
			for c in "$STORE_STAGE"/*/bin/"$interp"; do
				[ -x "$c" ] || continue
				found=$c
				break
			done
			[ -n "$found" ] || continue
			_echo " * $f runs '$interp $args', pointing it at the closure's own interpreter"
			sed -i "1s|.*|#!$STOREMAP/${found#"$STORE_STAGE"/} $args|" "$f"
		done
	done
}

_get_quick_sharun() {
	if [ -x "$QUICK_SHARUN" ]; then
		return 0
	fi
	_echo "Downloading quick-sharun..."
	mkdir -p "${QUICK_SHARUN%/*}"
	if _is_cmd wget; then
		wget -qO "$QUICK_SHARUN" "$QUICK_SHARUN_LINK"
	elif _is_cmd curl; then
		curl -Lso "$QUICK_SHARUN" "$QUICK_SHARUN_LINK"
	else
		_err_msg "ERROR: we need wget or curl to download quick-sharun"
		exit 1
	fi
	chmod +x "$QUICK_SHARUN"
}

_get_desktop() {
	[ -n "$DESKTOP" ] && return 0
	dir=$FHS_STAGE/share/applications
	for f in "$dir/$APPNAME.desktop" "$dir"/*"$APPNAME"*.desktop; do
		[ -f "$f" ] || continue
		DESKTOP=$f
		_echo "Using desktop entry $f"
		return 0
	done
	# package and desktop entry names do not always agree in case
	f=$(find "$dir" -maxdepth 1 -iname "*$APPNAME*.desktop" 2>/dev/null | head -n 1 || :)
	if [ -n "$f" ] && [ -f "$f" ]; then
		DESKTOP=$f
		_echo "Using desktop entry $f"
		return 0
	fi
	# a command line application has no desktop entry, and quick-sharun
	# requires one: DUMMY makes it write a hidden one, which is what the
	# pkgforge AppImages of such applications do as well
	_err_msg "WARNING: no desktop entry found for '$APPNAME', using a dummy one!"
	_err_msg "Set DESKTOP to the .desktop file you want to use."
	DESKTOP=DUMMY
}

_find_icon() {
	name=$1
	for size in 512x512 256x256 192x192 128x128 96x96 64x64 48x48 scalable; do
		for ext in png svg; do
			for f in "$FHS_STAGE/share/icons/hicolor/$size/apps/$name.$ext"; do
				[ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
			done
			f=$(find "$FHS_STAGE/share/icons/hicolor/$size/apps" -maxdepth 1 \
				-iname "$name.$ext" 2>/dev/null | head -n 1 || :)
			[ -n "$f" ] && { printf '%s\n' "$f"; return 0; }
		done
	done
	# anywhere else the package may have put it
	f=$(find "$FHS_STAGE/share/pixmaps" "$FHS_STAGE/share/icons" -maxdepth 4 \
		\( -iname "$name.png" -o -iname "$name.svg" \) 2>/dev/null | head -n 1 || :)
	[ -n "$f" ] && printf '%s\n' "$f"
	return 0
}

_get_icon() {
	[ -n "$ICON" ] && return 0
	icon_name=$APPNAME
	if [ -f "$DESKTOP" ]; then
		i=$(awk -F'=' '/^Icon=/{print $2; exit}' "$DESKTOP")
		[ -z "$i" ] || icon_name=${i##*/}
	fi
	ICON=$(_find_icon "$icon_name")
	if [ -n "$ICON" ]; then
		_echo "Using icon $ICON"
		return 0
	fi
	# never invent an icon: DUMMY makes quick-sharun make an empty one
	_err_msg "WARNING: no icon found for '$icon_name', using a dummy icon!"
	_err_msg "Set ICON to the path of an icon you want to use."
	ICON=DUMMY
}

# ------------ main ------------

trap _cleanup EXIT INT TERM HUP

APPDIR=$(_abs "$APPDIR")
OUTPATH=$(_abs "$OUTPATH")
WORK=$(_abs "$WORK")
mkdir -p "$APPDIR" "$OUTPATH" "$WORK"

if [ -z "$APPNAME" ]; then
	_err_msg "ERROR: APPNAME is not set"
	exit 1
fi

OUT=$(_store_path)
_echo "Application: $OUT"

CLOSURE=$(_closure "$OUT")
if [ -z "$CLOSURE" ]; then
	_err_msg "ERROR: could not determine the closure of '$OUT'"
	exit 1
fi

# the replacement has to have the same length as the prefix it replaces,
# because it is substituted inside binaries as well
STOREMAP=/tmp/$(printf '%s\n' $CLOSURE | sha256sum | cut -c1-5)
if [ "${#STORE_PREFIX}" -ne "${#STOREMAP}" ]; then
	_err_msg "ERROR: STORE_PREFIX has to be 10 characters, '$STORE_PREFIX' is not"
	exit 1
fi
_echo "Relocating '$STORE_PREFIX' to '$STOREMAP'"

STORE_STAGE=$WORK/closure
FHS_STAGE=$WORK/usr
rm -rf "$WORK/closure" "$WORK/usr"
mkdir -p "$STORE_STAGE" "$FHS_STAGE"

_echo "Copying the closure..."
for p in $CLOSURE; do
	rel=${p#"$STORE_PREFIX"/}
	src=$STORE_ROOT/$rel
	if [ ! -d "$src" ]; then
		_err_msg "ERROR: '$src' does not exist, is STORE_ROOT correct?"
		exit 1
	fi
	cp -r "$src" "$STORE_STAGE/$rel"
done

# Nix store paths are read only, and we have to edit every file
chmod -R u+w "$STORE_STAGE"

_echo "Relocating store references..."
_relocate_files
_relocate_symlinks
_rewrite_desktop_exec

# the staged binaries are used by quick-sharun to find dlopened libraries, so
# the prefix they reference has to resolve while we are still building, and
# the absolute store symlinks have to be dereferenceable
_relocated_view "$STORE_STAGE"

_echo "Staging the closure as a /usr-like tree..."
_stage_fhs

# from here on the prefix resolves to the merged /usr view, so that whatever
# quick-sharun pulls out of the staged binaries is deployed flat
_relocated_view "$FHS_STAGE"

_add_store_hook
_get_desktop
_get_icon

if [ ! -x "$FHS_STAGE/bin/$MAIN_BIN" ]; then
	if [ -x "$FHS_STAGE/sbin/$MAIN_BIN" ]; then
		MAIN_BIN_PATH=$FHS_STAGE/sbin/$MAIN_BIN
	else
		_err_msg "ERROR: '$MAIN_BIN' is not in $FHS_STAGE/bin or $FHS_STAGE/sbin"
		_err_msg "Set MAIN_BIN to the name of the binary to launch"
		exit 1
	fi
else
	MAIN_BIN_PATH=$FHS_STAGE/bin/$MAIN_BIN
fi

LD_PATH=$(ls "$FHS_STAGE"/lib/ld-*.so* 2>/dev/null | head -n 1 || :)
if [ -z "$LD_PATH" ]; then
	_err_msg "ERROR: no dynamic linker found in '$FHS_STAGE/lib'"
	exit 1
fi

_get_quick_sharun

# quick-sharun copies $LOCALE_DIR into the AppImage, and a closure without
# locales is not an error, so point it at an empty directory in that case
if [ ! -d "$FHS_STAGE/share/locale" ]; then
	mkdir -p "$WORK/empty/locale"
	LOCALE_DIR=$WORK/empty/locale
else
	LOCALE_DIR=$FHS_STAGE/share/locale
fi

# quick-sharun takes an application that is installed to /usr. Our /usr is the
# staged tree, LIB_DIR points at it, so every library that ends up in the
# AppImage comes from the closure and not from the build host
set -- "$MAIN_BIN_PATH" "$LD_PATH"

# a Nix package can have a wrapper script as its entry point, which is what
# makeWrapper produces, and quick-sharun rewrites its shebang to
# '#!/usr/bin/env <interpreter>'. sharun puts $APPDIR/bin on PATH, so the
# interpreter has to be deployed like any other binary or the wrapper cannot
# run.
if [ "$(head -c 2 "$MAIN_BIN_PATH" 2>/dev/null || :)" = '#!' ]; then
	interp=$(sed -n '1{s|^#![[:space:]]*||;p;}' "$MAIN_BIN_PATH" \
		| awk '{ for (i = 1; i <= NF; i++) { \
			if ($i ~ /^env$/ || $i ~ /\/env$/ || $i ~ /^-/) continue; \
			print $i; exit } }')
	interp=${interp##*/}
	for d in bin sbin; do
		[ -n "$interp" ] || break
		[ -x "$FHS_STAGE/$d/$interp" ] || continue
		_echo "The entry point is a script, deploying '$interp' too"
		set -- "$@" "$FHS_STAGE/$d/$interp"
		break
	done
fi
if [ -d "$FHS_STAGE/share/$APPNAME" ]; then
	set -- "$@" "$FHS_STAGE/share/$APPNAME"
fi

_echo "Deploying with quick-sharun..."
APPDIR="$APPDIR" \
LIB_DIR="$FHS_STAGE/lib" \
LOCALE_DIR="$LOCALE_DIR" \
DEPLOY_DATADIR=0 \
MAIN_BIN="$MAIN_BIN" \
DESKTOP="$DESKTOP" \
ICON="$ICON" \
OUTPATH="$OUTPATH" \
OUTNAME="$OUTNAME" \
"$QUICK_SHARUN" "$@"

_fix_script_shebangs

# the closure ships inside the AppImage, so that every store path the
# application and its children still reference by name resolves
_cleanup
_echo "Adding the closure to the AppDir..."
rm -rf "$APPDIR/nix/store"
mkdir -p "$APPDIR/nix"
cp -r "$STORE_STAGE" "$APPDIR/nix/store"

APPDIR="$APPDIR" \
MAIN_BIN="$MAIN_BIN" \
DESKTOP="$DESKTOP" \
ICON="$ICON" \
OUTPATH="$OUTPATH" \
OUTNAME="$OUTNAME" \
"$QUICK_SHARUN" --make-appimage
