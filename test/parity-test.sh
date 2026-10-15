#!/bin/sh
#
# Compare AppImages built from Nix against the pkgforge-dev AppImage of the
# same application, for applications that both nixpkgs and pkgforge-dev build.
#
# Nix cannot run here (no /nix, no root, no namespaces), so the Nix side comes
# from the official binary cache instead: test/fetch-closure.py resolves the
# attribute on Hydra, walks the reference graph through the .narinfo files and
# unpacks the closure, verifying every path against its NarHash. That is the
# same closure 'nix build' would have produced, fetched a different way.
#
# For each application this then:
#   * builds an AppImage from that closure with niximage.sh
#   * downloads the pkgforge-dev AppImage of the same application
#   * runs both with the same arguments, on a machine with no /nix/store
#   * checks that every store path referenced inside our AppImage is present
#     in the closure it ships
#   * compares the versions the two builds report
#
# Usage: ./parity-test.sh [attr ...]
#   nothing      -> the whole list below
#   attr names   -> only those
# KEEP=1 keeps the stores, AppDirs and AppImages.

set -eu

TESTDIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TESTDIR/.." && pwd)
WORK=${WORK:-$ROOT/parity}
STORE=${STORE:-$WORK/store}
OFFICIAL=${OFFICIAL:-$WORK/official}
KEEP=${KEEP:-0}
RUNTIME=${RUNTIME:-20}

# application table: attribute, pkgforge-dev repository, arguments that make
# the application print its version and exit
_apps() {
	cat <<-EOF
	htop htop-AppImage --version
	alacritty alacritty-AppImage --version
	yt-dlp yt-dlp-AppImage --version
	EOF
}

TMP_DIR=$WORK/tmp
mkdir -p "$WORK" "$STORE" "$OFFICIAL" "$TMP_DIR"

_fail() {
	echo "FAIL: $*" >&2
	exit 1
}

_wanted() {
	[ "$#" -eq 0 ] && return 0
	for want do
		[ "$want" = "$ATTR" ] && return 0
	done
	return 1
}

# run an AppImage on a machine with no /nix/store, no display and no FUSE
_run() {
	name=$1
	image=$2
	target=$3
	args=$4
	out=$WORK/run-$name.txt
	rm -rf "$target"
	# shellcheck disable=SC2086
	env -i PATH=/usr/bin:/bin HOME="${HOME:-/tmp}" \
		APPIMAGE_EXTRACT_AND_RUN=1 \
		APPIMAGE_TARGET_DIR="$target" \
		timeout "$RUNTIME" "$image" $args > "$out" 2>&1 </dev/null || {
		echo "  exit code: $? (failed)"
		tr '\r' '\n' < "$out" | tail -n 3 | sed 's/^/  | /'
		RUN_OK=0
		RUN_OUT=
		RUN_ALL=
		return 0
	}
	RUN_OK=1
	# the runtime prints its extraction progress with carriage returns, and
	# a pkgforge AppImage may print an updater notice before anything else
	RUN_ALL=$(tr '\r' '\n' < "$out" | sed 's/[0-9]\+%//g' | grep -v '^[[:space:]]*$' || :)
	RUN_OUT=$(printf '%s\n' "$RUN_ALL" | awk 'NF { print; exit }')
	echo "  output   : $RUN_OUT"
}

_version_of() {
	printf '%s\n' "$1" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^v?[0-9]+(\.[0-9]+)+/) { print $i; exit } }'
}

# the deployed libraries have to be enough for the deployed binaries: this is
# the view sharun gives the application at runtime, and anything 'not found'
# means the AppImage would have to borrow it from the host
_missing_libraries() {
	appdir=$1
	[ -d "$appdir/lib" ] || return 0
	find "$appdir/lib" "$appdir/shared/bin" -type f \
		\( -name '*.so*' -o -perm -u+x \) 2>/dev/null \
		-exec env LD_LIBRARY_PATH="$appdir/lib" ldd {} + 2>/dev/null \
		| awk '/not found/ { print $1 }' | sort -u | head -n 10
}

printf '%-12s %-10s %-10s %-9s %-9s %s\n' application nix pkgforge nix-size pkg-size version
printf '%s\n' "------------------------------------------------------------------------------"

ROWS=$WORK/rows.txt
: > "$ROWS"
FAILED=
while read -r ATTR REPO ARGS; do
	[ -n "$ATTR" ] || continue
	_wanted "$@" || continue

	echo
	echo "== $ATTR =="
	CLOSURE_FILE=$WORK/$ATTR.closure
	# shellcheck disable=SC2086
	# shellcheck disable=SC2155
	ROOT_PATH=$("$TESTDIR/fetch-closure.py" --attr "$ATTR" --dest "$STORE" \
		--closure-file "$CLOSURE_FILE" | tail -n 1)
	echo "  closure  : $ROOT_PATH"

	BUILD=$WORK/$ATTR
	rm -rf "$BUILD"
	mkdir -p "$BUILD"
	APPNAME=$ATTR MAIN_BIN=$ATTR \
	APP_STORE_PATH=$ROOT_PATH \
	STORE_ROOT=$STORE \
	CLOSURE_FILE=$CLOSURE_FILE \
	APPDIR=$BUILD/AppDir WORK=$BUILD/work OUTPATH=$BUILD/dist \
	TMPDIR=$TMP_DIR \
		"$ROOT/niximage.sh" > "$BUILD/build.log" 2>&1 \
		|| { tail -n 20 "$BUILD/build.log" | sed 's/^/  | /'; FAILED="$FAILED $ATTR(build)"; continue; }
	OUR_IMAGE=$BUILD/dist/$ATTR-x86_64.AppImage

	URL=$(gh api "repos/pkgforge-dev/$REPO/releases/latest" \
		--jq '[.assets[] | select(.name | test("x86_64")) | select(.name | endswith("AppImage"))][0].browser_download_url' 2>/dev/null || :)
	THEIR_IMAGE=$OFFICIAL/$ATTR.AppImage
	if [ -z "$URL" ] || [ "$URL" = null ]; then
		echo "  pkgforge : no release asset found in pkgforge-dev/$REPO"
		FAILED="$FAILED $ATTR(no-release)"
		continue
	fi
	[ -f "$THEIR_IMAGE" ] || curl -sL --max-time 900 -o "$THEIR_IMAGE" "$URL" \
		|| { echo "  pkgforge : download failed"; FAILED="$FAILED $ATTR(download)"; continue; }
	chmod +x "$THEIR_IMAGE"

	echo "  ours     :"
	_run "$ATTR-nix" "$OUR_IMAGE" "$BUILD/run" "$ARGS"
	OUR_OK=$RUN_OK
	OUR_OUT=$RUN_OUT
	echo "  pkgforge :"
	_run "$ATTR-pkgforge" "$THEIR_IMAGE" "$BUILD/run-official" "$ARGS"
	THEIR_OK=$RUN_OK
	THEIR_OUT=$RUN_OUT
	THEIR_ALL=$RUN_ALL

	# the two builds are not expected to be byte identical: they come from
	# different packagers at different times. What has to hold is that the
	# version our Nix built application reports is the version the pkgforge
	# build of the same application reports
	OUR_VER=$(_version_of "${OUR_OUT:-}")
	THEIR_VER=$(_version_of "${THEIR_OUT:-}")
	VERSION=ok
	if [ -z "$OUR_VER" ]; then
		VERSION="no version reported"
	elif [ "${THEIR_ALL#*"$OUR_VER"}" = "$THEIR_ALL" ]; then
		VERSION="differs: ours $OUR_VER, pkgforge ${THEIR_VER:-unknown}"
	fi

	MISSING=$(_missing_libraries "$BUILD/run" || :)
	if [ -n "$MISSING" ]; then
		echo "  missing  : $MISSING"
		FAILED="$FAILED $ATTR(missing-libs)"
	fi
	[ "$OUR_OK" = 1 ] || FAILED="$FAILED $ATTR(run)"
	[ "$THEIR_OK" = 1 ] || FAILED="$FAILED $ATTR(pkgforge-run)"

	printf '%-12s %-10s %-10s %-9s %-9s %s\n' "$ATTR" \
		"$([ "$OUR_OK" = 1 ] && echo ok || echo failed)" \
		"$([ "$THEIR_OK" = 1 ] && echo ok || echo failed)" \
		"$(du -h "$OUR_IMAGE" | cut -f1)" \
		"$(du -h "$THEIR_IMAGE" | cut -f1)" \
		"$VERSION" >> "$ROWS"

	if [ "$KEEP" != 1 ]; then
		rm -rf "$BUILD/AppDir" "$BUILD/work"
	fi
done <<-EOF
$(_apps)
EOF

echo
echo "======================================================================"
cat "$ROWS"
echo "======================================================================"
echo
if [ -n "$FAILED" ]; then
	_fail "problems:$FAILED"
fi
echo "All applications ran, from the closures that were fetched for them."
