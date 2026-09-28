#!/usr/bin/env bash
# Fixed usbmuxd for an iPhone passed into WSL with usbipd-win.
#
# usbipd-win drops the zero-length USB packet that has to follow any transfer
# ending exactly on a packet boundary. Stock usbmuxd sends full packets of
# 49,152 bytes, which always end on a boundary, so large copies to the phone
# (installing an app) hang for good. Small messages like pairing still work.
#
# This builds Ubuntu's own usbmuxd with a small patch that never lets a transfer
# end on a boundary, then runs it in place of the stock one.
#
# Run inside Ubuntu (WSL):
#   curl -fsSL https://raw.githubusercontent.com/colin493/film-meter/main/tools/usbmuxd-wsl.sh | bash
#
# Undo:
#   sudo pkill -x usbmuxd-wsl; sudo systemctl unmask usbmuxd
set -euo pipefail

PATCH_URL="${PATCH_URL:-https://raw.githubusercontent.com/colin493/film-meter/main/tools/usbmuxd-wsl-zlp.patch}"
WORK="${WORK:-$HOME/usbmuxd-wsl}"
BIN=/usr/local/sbin/usbmuxd-wsl

say() { printf '\n== %s\n' "$*"; }

say "Installing build tools (asks for your Ubuntu password)"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential autoconf automake libtool \
  pkg-config dpkg-dev curl patch libusb-1.0-0-dev libplist-dev libimobiledevice-dev > /dev/null

say "Downloading Ubuntu's usbmuxd source"
SRC_LIST=/etc/apt/sources.list.d/usbmuxd-wsl-src.sources
MIRROR=$(awk '/^URIs:/ {print $2; exit}' /etc/apt/sources.list.d/ubuntu.sources 2> /dev/null || true)
if [ -z "$MIRROR" ]; then
  if [ "$(dpkg --print-architecture)" = amd64 ]; then MIRROR=http://archive.ubuntu.com/ubuntu/; else MIRROR=http://ports.ubuntu.com/ubuntu-ports/; fi
fi
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
sudo tee "$SRC_LIST" > /dev/null << EOF
Types: deb-src
URIs: $MIRROR
Suites: $CODENAME $CODENAME-updates $CODENAME-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
sudo apt-get update -qq
rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK"
apt-get source -qq usbmuxd > /dev/null 2>&1
sudo rm -f "$SRC_LIST"
cd "$(find . -maxdepth 1 -type d -name 'usbmuxd-*' | head -n1)"

say "Applying the fix"
if [ -n "${PATCH_FILE:-}" ]; then patch -p1 < "$PATCH_FILE"; else curl -fsSL "$PATCH_URL" | patch -p1; fi

say "Building"
autoreconf -fi > /dev/null 2>&1
./configure -q --without-systemd > /dev/null
make -s -j"$(nproc)" > /dev/null 2>&1
sudo install -m 755 src/usbmuxd "$BIN"
echo "Built $BIN"

if [ -n "${BUILD_ONLY:-}" ]; then exit 0; fi

say "Swapping in the fixed usbmuxd"
sudo systemctl stop usbmuxd > /dev/null 2>&1 || true
sudo systemctl mask usbmuxd > /dev/null 2>&1 || true
sudo pkill -x usbmuxd 2> /dev/null || true
sudo pkill -x usbmuxd-wsl 2> /dev/null || true
sleep 2
sudo "$BIN" -v
sleep 3

if pgrep -x usbmuxd-wsl > /dev/null; then
  echo "The fixed usbmuxd is running."
else
  echo "The fixed usbmuxd didn't start. Paste this whole window to Claude."
  exit 1
fi

say "Looking for your iPhone"
for _ in 1 2 3 4 5; do
  ID=$(idevice_id -l 2> /dev/null | head -n1 || true)
  [ -n "$ID" ] && break
  sleep 2
done
if [ -n "${ID:-}" ]; then
  echo "Found your iPhone ($ID). Start iloader again and install SideStore."
else
  echo "No iPhone yet. Unplug it, plug it back in and unlock it, then run: idevice_id -l"
fi
