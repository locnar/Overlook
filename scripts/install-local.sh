#!/bin/bash
# Build the Release configuration and install it as Overlook.app in /Applications
# (or in the folder given as the first argument, e.g. ~/Applications).
#
# The app is signed "to run locally" (ad-hoc) unless a Team is set in the project;
# that is all a Mac needs to run something it built itself. An ad-hoc signature is
# different for every build, so on first launch after each install the login keychain
# asks whether Overlook may read its saved device tokens and passwords — choose
# Always Allow. Setting a Team (Signing & Capabilities) gives a stable identity and
# stops the prompts.
set -euo pipefail

cd "$(dirname "$0")/.."

DERIVED="build/release-local"
APP="$DERIVED/Build/Products/Release/Overlook.app"
DEST_DIR="${1:-/Applications}"
DEST="$DEST_DIR/Overlook.app"

echo "Building Release…"
xcodebuild -project Overlook.xcodeproj -scheme Overlook -configuration Release \
  -derivedDataPath "$DERIVED" -quiet build

codesign --verify --strict --deep "$APP"

if pgrep -xq Overlook; then
  echo "Quitting the running copy…"
  osascript -e 'tell application "Overlook" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq Overlook || break; sleep 0.5; done
  pgrep -xq Overlook && { echo "Overlook is still running; quit it and rerun." >&2; exit 1; }
fi

rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "Installed $DEST"
open "$DEST"
