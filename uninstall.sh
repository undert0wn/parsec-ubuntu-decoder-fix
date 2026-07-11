#!/usr/bin/env bash
#
# Reverts install.sh: removes the compat library folder and the desktop
# launcher override. Does not touch Parsec itself or any system package.

set -euo pipefail

COMPAT_DIR="$HOME/.parsec/compat-libs"
DESKTOP_FILE="$HOME/.local/share/applications/parsecd.desktop"

log() { printf '\033[1;32m==>\033[0m %s\n' "$1"; }

if [ -d "$COMPAT_DIR" ]; then
  rm -rf "$COMPAT_DIR"
  log "Removed $COMPAT_DIR"
fi

if [ -f "$DESKTOP_FILE" ]; then
  rm -f "$DESKTOP_FILE"
  log "Removed $DESKTOP_FILE"
fi

command -v update-desktop-database >/dev/null 2>&1 && \
  update-desktop-database "$(dirname "$DESKTOP_FILE")" >/dev/null 2>&1 || true

log "Done. Parsec will go back to using only system libraries (and Error 17"
log "will likely return on this OS version, since that's the whole reason"
log "this fix existed)."
