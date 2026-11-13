#!/bin/zsh
# Builds Runbar.app into build/. With "install", also copies it to ~/Applications
# and restarts it.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
bin="$(swift build -c release --show-bin-path)/runbar"

app=build/Runbar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/runbar"
cp Resources/Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# Ad-hoc signature: enough for notifications and Launch at Login on this Mac.
codesign --force --sign - --identifier local.runbar "$app"
echo "Built $app"

if [[ "${1:-}" == "install" ]]; then
  dest="$HOME/Applications/Runbar.app"
  mkdir -p "$HOME/Applications"
  pkill -x runbar 2>/dev/null && sleep 0.5 || true
  rm -rf "$dest"
  cp -R "$app" "$dest"
  open "$dest"
  echo "Installed $dest"
fi
