#!/bin/sh
#
# The smallest useful run: nixpkgs hello, with no desktop entry and no icon.
# niximage will say so and use a dummy icon on purpose, it never invents one.

set -eu

cd "$(dirname "$0")/.."

APPNAME=hello \
MAIN_BIN=hello \
APP_REF=nixpkgs#hello \
	./niximage.sh
