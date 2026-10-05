#!/bin/zsh
# Renders the app icon (Holdfast/Holdfast.icon) into docs/images/icon-light.png and icon-dark.png for the README,
# with the ictool inside Xcode's Icon Composer. Run it again after changing the icon.
# Usage: Tools/app_icon.sh [size in pixels, default 256]
cd "$(dirname "$0")/.."
ictool="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x $ictool ]] || { echo "ictool not found: $ictool"; exit 1 }
size=${1:-256}
mkdir -p docs/images
for rendition name in Default light Dark dark; do
  "$ictool" Holdfast/Holdfast.icon --export-image --output-file docs/images/icon-$name.png \
    --platform macOS --rendition $rendition --width $size --height $size --scale 1 >/dev/null || exit 1
  echo docs/images/icon-$name.png
done
