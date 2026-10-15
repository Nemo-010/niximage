#!/bin/sh
#
# A real desktop application. retroarch is a good example because nixpkgs
# gives it a wrapper script as its entry point, so niximage has to deploy the
# interpreter that script names as well as the application itself.
#
# DESKTOP and ICON are looked up in the staged tree; set them here if your
# package keeps them somewhere else.

set -eu

cd "$(dirname "$0")/.."

APPNAME=retroarch \
MAIN_BIN=retroarch \
APP_REF=nixpkgs#retroarch \
	./niximage.sh
