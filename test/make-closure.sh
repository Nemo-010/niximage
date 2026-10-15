#!/bin/sh
#
# Synthesise a Nix-flavoured closure for the test suite.
#
# Nix is not available everywhere this project is developed in, so the test
# suite builds a store tree that has every property a real one has:
#
#   * store paths of the form /nix/store/<32 nix-base32 chars>-<name>
#   * ELF binaries whose interpreter and rpath point at those store paths
#   * store paths compiled into a binary as data, dlopen and exec targets
#   * a script with a /nix/store interpreter shebang
#   * relative and absolute symlinks into the store
#   * read only files and directories, like the real store
#
# The files live in a fake store root because creating /nix/store needs root,
# which is exactly the situation the AppImage has to survive: nothing may
# depend on /nix/store existing at runtime.

set -eu

TESTDIR=${TESTDIR:-$(cd "$(dirname "$0")" && pwd)}
STORE=${STORE:-$TESTDIR/tmp/store}
OUT=${OUT:-$TESTDIR/tmp}
CC=${CC:-cc}

GLIBC_HASH=7z1s2v3w4x5y6z7a8b9c0d1f2g3h4j5k
NCURSES_HASH=1m2n3p4q5r6s7v8w9x0y1z2a3b4c5d6f
BASH_HASH=3a4b5c6d7f8g9h0j1k2l3m4n5p6q7r8s
LIBHELLO_HASH=9v0w1x2y3z4a5b6c7d8f9g0h1j2k3l4m
HELPER_HASH=7g8h9j0k1l2m3n4p5q6r7s8v9w0x1y2z
HELLO_HASH=3f4g5h6j7k8l9m0n1p2q3r4s5v6w7x8y

GLIBC=$GLIBC_HASH-glibc-2.44
NCURSES=$NCURSES_HASH-ncurses-6.5
BASH=$BASH_HASH-bash-5.2-p39
LIBHELLO=$LIBHELLO_HASH-libhello-1.0
HELPER=$HELPER_HASH-hello-helper-1.0
HELLO=$HELLO_HASH-hello-2.12.1

GLIBC_LIB=/nix/store/$GLIBC/lib
NCURSES_LIB=/nix/store/$NCURSES/lib
BASH_BIN=/nix/store/$BASH/bin/bash
HELLO_SHARE=/nix/store/$HELLO/share

echo "Building the fake store at $STORE"
chmod -R u+w "$STORE" 2>/dev/null || :
rm -rf "$STORE"
mkdir -p "$OUT"

for d in "$GLIBC/lib" "$NCURSES/lib" "$BASH/bin" "$LIBHELLO/lib" \
         "$HELPER/bin" "$HELLO/bin" "$HELLO/share/hello" \
         "$HELLO/share/applications" \
         "$HELLO/share/icons/hicolor/256x256/apps"; do
	mkdir -p "$STORE/$d"
done

# ---- glibc: the dynamic linker and the C library ----
# taken from the host, so that the test binaries really run
for lib in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 \
           libutil.so.1 libresolv.so.2 libnss_files.so.2 libgcc_s.so.1 \
           ld-linux-x86-64.so.2; do
	cp "/usr/lib/$lib" "$STORE/$GLIBC/lib/$lib"
done

# ---- ncurses: libraries bash needs, with store symlinks ----
cp /usr/lib/libreadline.so.8.3 "$STORE/$NCURSES/lib/"
cp /usr/lib/libncursesw.so.6.6 "$STORE/$NCURSES/lib/"
ln -s libreadline.so.8.3 "$STORE/$NCURSES/lib/libreadline.so.8"
ln -s libncursesw.so.6.6 "$STORE/$NCURSES/lib/libncursesw.so.6"
# an absolute symlink into the store, like packages that share a library
ln -s "/nix/store/$NCURSES/lib/libncursesw.so.6" "$STORE/$NCURSES/lib/libtinfo.so.6"

# ---- bash ----
cp /usr/bin/bash "$STORE/$BASH/bin/bash"

# ---- the application and its own store references ----
cat > "$OUT/hello.c" <<-EOF
	/* stand in for a Nix built application */
	#include <stdio.h>
	#include <stdlib.h>
	#include <dlfcn.h>
	#include <unistd.h>
	#include <sys/wait.h>

	#define DATA   "$HELLO_SHARE/hello/data.txt"
	#define LIB    "/nix/store/$LIBHELLO/lib/libhello.so.1"
	#define HELPER "/nix/store/$HELPER/bin/hello-helper"
	#define SCRIPT "/nix/store/$HELLO/bin/hello-script"

	static void run(const char *what, const char *path)
	{
	        pid_t pid = fork();
	        if (pid == 0) {
	                execl(path, path, (char *)NULL);
	                _exit(127);
	        }
	        if (pid < 0) {
	                perror("fork");
	                return;
	        }
	        int status = 0;
	        waitpid(pid, &status, 0);
	        printf("%s: exit %d\\n", what, WEXITSTATUS(status));
	}

	int main(void)
	{
	        char exe[512];
	        ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
	        if (n > 0) {
	                exe[n] = 0;
	                printf("EXE: %s\\n", exe);
	        }

	        FILE *f = fopen(DATA, "r");
	        char buf[128] = "";
	        if (f) {
	                if (fgets(buf, sizeof buf, f)) { /* keep it */ }
	                fclose(f);
	        }
	        printf("DATA: %s", buf);

	        char *real = realpath(DATA, NULL);
	        if (real) {
	                printf("REALPATH: %s\\n", real);
	                free(real);
	        }

	        void *h = dlopen(LIB, RTLD_NOW);
	        printf("DLOPEN: %s\\n", h ? "ok" : dlerror());

	        run("HELPER", HELPER);
	        run("SCRIPT", SCRIPT);
	        return 0;
	}
EOF

cat > "$OUT/libhello.c" <<-EOF
	#include <stdio.h>

	static void libhello_init(void) __attribute__((constructor));
	static void libhello_init(void)
	{
	        printf("LIBHELLO: loaded\\n");
	}
EOF

cat > "$OUT/hello-helper.c" <<-EOF
	#include <stdio.h>

	int main(void)
	{
	        printf("HELPER: ran\\n");
	        return 0;
	}
EOF

$CC -shared -fPIC -o "$STORE/$LIBHELLO/lib/libhello.so.1" "$OUT/libhello.c"
$CC -o "$STORE/$HELPER/bin/hello-helper" "$OUT/hello-helper.c"
$CC -o "$STORE/$HELLO/bin/hello" "$OUT/hello.c" -ldl

printf 'niximage test data\n' > "$STORE/$HELLO/share/hello/data.txt"

cat > "$STORE/$HELLO/bin/hello-script" <<-EOF
	#!$BASH_BIN
	echo "SCRIPT: ran with bash \$BASH_VERSION"
EOF
chmod 755 "$STORE/$HELLO/bin/hello-script"

cat > "$STORE/$HELLO/share/applications/hello.desktop" <<-EOF
	[Desktop Entry]
	Type=Application
	Name=hello
	Comment=a NixImage test application
	Exec=hello
	Icon=hello
	Categories=Utility;
	Terminal=true
EOF

python3 - "$STORE/$HELLO/share/icons/hicolor/256x256/apps/hello.png" <<-'PY'
	# a real 1x1 PNG, so nothing in the packaging chain chokes on it
	import struct, sys, zlib
	raw = b'\x00\x00\x00\x00\xff'          # one RGBA pixel, filter byte
	def chunk(kind, data):
	    return (struct.pack('>I', len(data)) + kind + data
	            + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff))
	png = (b'\x89PNG\r\n\x1a\n'
	       + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))
	       + chunk(b'IDAT', zlib.compress(raw))
	       + chunk(b'IEND', b''))
	open(sys.argv[1], 'wb').write(png)
PY

# ---- give every binary the store interpreter and rpath it would get from
# ---- Nix, and keep everything read only like the real store
for lib in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 \
           libutil.so.1 libresolv.so.2 libnss_files.so.2 libgcc_s.so.1; do
	patchelf --set-rpath "$GLIBC_LIB" "$STORE/$GLIBC/lib/$lib"
done

for lib in libreadline.so.8.3 libncursesw.so.6.6; do
	patchelf --set-rpath "$GLIBC_LIB:$NCURSES_LIB" "$STORE/$NCURSES/lib/$lib"
done

patchelf --set-interpreter "$GLIBC_LIB/ld-linux-x86-64.so.2" \
         --set-rpath "$GLIBC_LIB:$NCURSES_LIB" \
         "$STORE/$BASH/bin/bash"

patchelf --set-rpath "$GLIBC_LIB" "$STORE/$LIBHELLO/lib/libhello.so.1"

patchelf --set-interpreter "$GLIBC_LIB/ld-linux-x86-64.so.2" \
         --set-rpath "$GLIBC_LIB" \
         "$STORE/$HELPER/bin/hello-helper"

patchelf --set-interpreter "$GLIBC_LIB/ld-linux-x86-64.so.2" \
         --set-rpath "$GLIBC_LIB:/nix/store/$LIBHELLO/lib" \
         "$STORE/$HELLO/bin/hello"

# the interpreter of a store binary is an absolute store path, exactly like
# it is for a real Nix package
printf '%s\n' \
	"/nix/store/$GLIBC" \
	"/nix/store/$NCURSES" \
	"/nix/store/$BASH" \
	"/nix/store/$LIBHELLO" \
	"/nix/store/$HELPER" \
	"/nix/store/$HELLO" > "$OUT/closure.txt"

printf '%s\n' "/nix/store/$HELLO" > "$OUT/app.txt"

# what the fake nix CLI answers with
printf '%s\n' "$OUT/closure.txt" > "$OUT/closure-file.txt"

chmod -R a-w "$STORE"
echo "Closure written to $OUT/closure.txt"
