#!/bin/sh
# Launch bootstrap for the canonical MIT installer. The fetched script verifies
# release archives and checksums from:
# https://github.com/burnban/burnban/releases/latest/download/
set -eu

installer_url="https://raw.githubusercontent.com/burnban/burnban/main/install.sh"
tmp=$(mktemp "${TMPDIR:-/tmp}/burnban-install.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM
curl -fsSL "$installer_url" -o "$tmp"
sh "$tmp" "$@"
