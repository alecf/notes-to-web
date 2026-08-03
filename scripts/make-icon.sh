#!/bin/bash
# Rebuild Resources/AppIcon.icns from docs/logo.svg. Needs rsvg-convert
# (brew install librsvg). The generated .icns is committed, so this is only
# needed when the logo changes.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found: brew install librsvg"; exit 1; }

python3 - <<'PY'
mark = open('docs/logo.svg').read()
inner = mark.split('>', 1)[1].rsplit('</svg>', 1)[0]
open('Resources/AppIcon.svg', 'w').write(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">\n'
    '  <!-- Generated from docs/logo.svg by scripts/make-icon.sh. Edit the logo, not this. -->\n'
    '  <g transform="translate(100 100) scale(1.609375)">' + inner + '</g>\n'
    '</svg>\n'
)
PY

SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  set -- $spec
  rsvg-convert -w "$1" -h "$1" Resources/AppIcon.svg -o "$SET/icon_$2.png"
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"
