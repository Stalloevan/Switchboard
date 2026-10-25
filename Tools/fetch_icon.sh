#!/bin/bash
# Downloads the Matter logo (Dashboard Icons by Homarr Labs) and builds the 1024px app icon.
# Records the source URL in Tools/icon-source.txt for the release notes.
set -euo pipefail

url="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/matter.png"
out_dir="Switchboard/Assets.xcassets/AppIcon.appiconset"
tmp="$(mktemp -d)"
mkdir -p "$out_dir"

curl -fsSL --max-time 60 -o "$tmp/src.png" "$url"
if ! file "$tmp/src.png" | grep -q "PNG image"; then
  echo "::error::Downloaded file from $url is not a PNG"
  exit 1
fi

echo "$url" > Tools/icon-source.txt

python3 -m venv "$tmp/venv"
"$tmp/venv/bin/pip" install --quiet pillow
"$tmp/venv/bin/python" Tools/make_icon.py "$tmp/src.png" "$out_dir/icon.png"
cp "$out_dir/icon.png" AppIcon-1024.png
