#!/bin/bash
# Downloads the Matter icon from Icons8 and builds the app icon. Prints the source URL to Tools/icon-source.txt.
set -euo pipefail

out_dir="Switchboard/Assets.xcassets/AppIcon.appiconset"
tmp="$(mktemp -d)"
found=""
tried=""

for name in matter matter-logo; do
  for style in fluency color ios-filled ios material-rounded glyph-neue nolan office; do
    for size in 1024 512 256; do
      url="https://img.icons8.com/$style/$size/$name.png"
      tried="$tried $url"
      if curl -fsSL --max-time 30 -o "$tmp/src.png" "$url" 2>/dev/null \
         && file "$tmp/src.png" | grep -q "PNG image" \
         && [ "$(stat -f%z "$tmp/src.png")" -gt 1500 ]; then
        found="$url"
        break 3
      fi
    done
  done
done

if [ -z "$found" ]; then
  echo "::error::No Matter icon found on icons8. Tried:$tried"
  exit 1
fi

echo "Using icon: $found"
echo "$found" > Tools/icon-source.txt

python3 -m venv "$tmp/venv"
"$tmp/venv/bin/pip" install --quiet pillow
"$tmp/venv/bin/python" Tools/make_icon.py "$tmp/src.png" "$out_dir/icon.png"
cp "$out_dir/icon.png" AppIcon-1024.png
