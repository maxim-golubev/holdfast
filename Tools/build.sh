#!/bin/zsh
# Builds the app (Release) into ./build and prints the .app path. Exits non-zero on failure.
# Usage: Tools/build.sh [-q]
cd "$(dirname "$0")/.."
out=$(xcodebuild -project Holdfast.xcodeproj -scheme Holdfast -configuration Release \
  -derivedDataPath build build 2>&1)
rc=$?
echo "$out" | grep -E 'error:|BUILD (SUCCEEDED|FAILED)' | sort -u
[ "$1" = "-q" ] || echo "$out" | grep -E 'warning:' | grep -v -E 'SourcePackages|appintentsmetadataprocessor' | sort -u | head -40
[ $rc -eq 0 ] && ls -d build/Build/Products/Release/Holdfast.app
exit $rc
