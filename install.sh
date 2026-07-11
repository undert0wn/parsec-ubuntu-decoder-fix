#!/usr/bin/env bash
#
# A workaround for Parsec Linux client Error 17 (video decoder failure)
# that resolved the issue on Ubuntu 26.04. It has NOT been confirmed on
# other Ubuntu versions (e.g. 24.04) or other distros — see README.md
# before running this on anything other than 26.04.
#
# What seems to be going on: Parsec's Linux client appears to be
# dynamically linked against FFmpeg ~4.4 SONAMEs (libavcodec.so.58,
# libavutil.so.56) that shipped with Ubuntu 22.04 and were removed from
# later releases. This script fetches those exact libraries (and their
# own dependencies) from Ubuntu's official archive, and installs them
# into a folder that only Parsec is pointed at — nothing under /usr/lib
# is touched, and no system package state is modified, so it shouldn't
# be able to affect any other application on your system either way.
#
# Safe to re-run; it's idempotent.

set -euo pipefail

TESTED_VERSION="26.04"
COMPAT_DIR="$HOME/.parsec/compat-libs"
WORK_DIR="$(mktemp -d)"
DESKTOP_FILE="$HOME/.local/share/applications/parsecd.desktop"
SYSTEM_DESKTOP_FILE="/usr/share/applications/parsecd.desktop"

MIRRORS=(
  "http://archive.ubuntu.com/ubuntu/pool"
  "http://old-releases.ubuntu.com/ubuntu/pool"
)

# name | pool subpath | filename | sha256
PACKAGES=(
  "libavcodec58|universe/f/ffmpeg|libavcodec58_4.4.2-0ubuntu0.22.04.1_amd64.deb|2704a3c4283008daa293334f102ed2f32d056fc000df618d0ef98380e6ba18a1"
  "libavutil56|universe/f/ffmpeg|libavutil56_4.4.2-0ubuntu0.22.04.1_amd64.deb|79993e85a16cab6f8c4820677836fb957a9bcc09b102da472bc93250c531979a"
  "libswresample3|universe/f/ffmpeg|libswresample3_4.4.2-0ubuntu0.22.04.1_amd64.deb|3027189b2512eaa841c81593b8c65e0f32ff8117626b7e40f3744a0b3801fec5"
  "libvpx7|main/libv/libvpx|libvpx7_1.11.0-2ubuntu2.5_amd64.deb|5561f3376bb9232d098a44dabc33eed3b3abfeec751c27893b58b6e6912684e0"
  "libdav1d5|universe/d/dav1d|libdav1d5_0.9.2-1_amd64.deb|1f92d5961a84a6d1365e6fc9da9d1fbfb7988a47c7f3bee8403eb57cd67545cf"
  "libcodec2-1.0|universe/c/codec2|libcodec2-1.0_1.0.1-3_amd64.deb|1fbf2167aeb9dedea22c68b6166873d6b5ed0e854cbc4383f148fe20cbe7b142"
  "libtheora0|main/libt/libtheora|libtheora0_1.1.1+dfsg.1-15ubuntu4_amd64.deb|549485bfe7ad431b387aa084fd0e088b025feb3dcdb77a5a1d130b29a62875dd"
  "libx264-163|universe/x/x264|libx264-163_0.163.3060+git5db6aa6-2build1_amd64.deb|4b6dc88ca9fee6a234b599cfc67ce1042050dd2814f00b5065406bcdc75baf47"
  "libx265-199|universe/x/x265|libx265-199_3.5-2build1_amd64.deb|795a6ca9287cd521882178d6503703ee8f0cde955f0ffc03e5ceee9f6d084de7"
  "libmfx1|universe/i/intel-mediasdk|libmfx1_22.3.0-1_amd64.deb|a04a16280471ec59405290f6ca85d8252b3476bae5542b5e0a4e442c041f9a4a"
)

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

log()  { printf '\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$1" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
  die "Don't run this as root — it only writes to your home directory."
fi

command -v curl      >/dev/null 2>&1 || die "curl is required but not installed."
command -v dpkg-deb  >/dev/null 2>&1 || die "dpkg-deb is required but not installed."

detected_version=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  detected_version="${VERSION_ID:-}"
fi
if [ "$detected_version" != "$TESTED_VERSION" ]; then
  warn "This has only been confirmed working on Ubuntu $TESTED_VERSION."
  warn "Detected OS version: ${detected_version:-unknown}."
  warn "It may still work here (the underlying idea — supplying the old"
  warn "FFmpeg libraries Parsec expects — isn't specific to one release),"
  warn "but that has not been verified. Worth reading README.md before"
  warn "continuing, and please report back either way if you try it."
  read -r -p "Continue anyway? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || exit 0
fi

if [ ! -x /usr/bin/parsecd ]; then
  warn "Parsec (/usr/bin/parsecd) doesn't appear to be installed. Continuing anyway."
fi

if ldconfig -p 2>/dev/null | grep -q 'libavcodec\.so\.58'; then
  warn "libavcodec.so.58 already exists natively on this system."
  warn "You likely don't need this fix (are you already on Ubuntu 22.04?)."
  read -r -p "Continue anyway? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || exit 0
fi

mkdir -p "$COMPAT_DIR"
log "Installing compat libraries to $COMPAT_DIR"

download_with_fallback() {
  local subpath="$1" filename="$2" expected_sha="$3"
  local dest="$WORK_DIR/$filename"
  for mirror in "${MIRRORS[@]}"; do
    local url="$mirror/$subpath/$filename"
    if curl -sfL -o "$dest" "$url"; then
      local actual_sha
      actual_sha="$(sha256sum "$dest" | cut -d' ' -f1)"
      if [ "$actual_sha" = "$expected_sha" ]; then
        echo "$dest"
        return 0
      else
        warn "Checksum mismatch for $filename from $mirror, trying next mirror..."
        rm -f "$dest"
      fi
    fi
  done
  die "Failed to download $filename from any mirror (or it failed checksum verification everywhere)."
}

for entry in "${PACKAGES[@]}"; do
  IFS='|' read -r name subpath filename expected_sha <<< "$entry"
  log "Fetching $name..."
  deb_path="$(download_with_fallback "$subpath" "$filename" "$expected_sha")"
  extract_dir="$WORK_DIR/extract_$name"
  dpkg-deb -x "$deb_path" "$extract_dir"
  find "$extract_dir" -name '*.so*' -exec cp -Pf {} "$COMPAT_DIR/" \;
done

log "All libraries installed. Verifying dependency resolution..."
missing=0
for so in "$COMPAT_DIR"/libavcodec.so.58.* "$COMPAT_DIR"/libavutil.so.56.*; do
  [ -e "$so" ] || continue
  if LD_LIBRARY_PATH="$COMPAT_DIR" ldd "$so" 2>&1 | grep -q "not found"; then
    warn "Unresolved dependencies in $(basename "$so"):"
    LD_LIBRARY_PATH="$COMPAT_DIR" ldd "$so" 2>&1 | grep "not found"
    missing=1
  fi
done
[ "$missing" -eq 0 ] || die "Some dependencies are still unresolved — the fix may not work correctly."
log "Dependency check passed."

log "Setting up desktop launcher override..."
mkdir -p "$(dirname "$DESKTOP_FILE")"
if [ -f "$SYSTEM_DESKTOP_FILE" ]; then
  sed "s|^Exec=.*|Exec=env LD_LIBRARY_PATH=$COMPAT_DIR /usr/bin/parsecd %u|" \
    "$SYSTEM_DESKTOP_FILE" > "$DESKTOP_FILE"
else
  cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Parsec
GenericName=Parsec
Comment=Simple, low-latency game streaming.
Exec=env LD_LIBRARY_PATH=$COMPAT_DIR /usr/bin/parsecd %u
Icon=/usr/share/icons/hicolor/256x256/apps/parsecd.png
Terminal=false
Type=Application
Categories=Network;Game;Utility;
EOF
fi
command -v update-desktop-database >/dev/null 2>&1 && \
  update-desktop-database "$(dirname "$DESKTOP_FILE")" >/dev/null 2>&1 || true
log "Desktop launcher updated: $DESKTOP_FILE"

if pgrep -x parsecd >/dev/null 2>&1; then
  log "Restarting Parsec to apply the fix..."
  pkill parsecd || true
  sleep 1
fi
LD_LIBRARY_PATH="$COMPAT_DIR" nohup parsecd >/dev/null 2>&1 &
disown

log "Done. Parsec has been restarted with the fix applied."
log "Launching it from your desktop icon will also work correctly from now on."
