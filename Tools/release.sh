#!/bin/zsh
# Builds the release archive: a clean Release build, signed with the identity and team the project names, its
# signature verified before and after zipping, as build/release/Holdfast-<version>.zip. Prints the archive's path
# and SHA-256. Exits non-zero, leaving no archive, when the build or any check fails.
# Usage: Tools/release.sh
cd "$(dirname "$0")/.."
fail() { print -u2 -r -- "release: $1"; rm -f "${zip:-}"; rm -rf build/release/check; exit 1 }

settings=$(xcodebuild -project Holdfast.xcodeproj -scheme Holdfast -configuration Release -showBuildSettings 2>/dev/null) \
  || fail "the project's build settings cannot be read"
setting() { print -r -- "$settings" | sed -n "s/^ *$1 = //p" | head -1 }
identity=$(setting CODE_SIGN_IDENTITY)
team=$(setting DEVELOPMENT_TEAM)
[[ -n $identity && -n $team ]] || fail "the project names no signing identity or team"

out=$(xcodebuild -project Holdfast.xcodeproj -scheme Holdfast -configuration Release -derivedDataPath build clean build 2>&1)
rc=$?
print -r -- "$out" | grep -E 'error:|BUILD (SUCCEEDED|FAILED)' | sort -u
(( rc == 0 )) || fail "the build failed"
app=build/Build/Products/Release/Holdfast.app
[[ -d $app ]] || fail "no app at $app"

# The signature holds, is the project's, and has the hardened runtime
codesign --verify --deep --strict "$app" || fail "the signature of $app does not verify"
signature=$(codesign -dvv "$app" 2>&1)
print -r -- "$signature" | grep -q "^Authority=$identity" || fail "$app is not signed with \"$identity\""
print -r -- "$signature" | grep -q "^TeamIdentifier=$team\$" || fail "$app is not signed by team $team"
print -r -- "$signature" | grep -q '^CodeDirectory.*flags=.*runtime' || fail "$app is not signed with the hardened runtime"

version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist") || fail "the app has no version"
mkdir -p build/release
zip=build/release/Holdfast-$version.zip
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip" || fail "the archive could not be written"

# What a download unpacks to must verify too
rm -rf build/release/check
ditto -x -k "$zip" build/release/check || fail "the archive cannot be unpacked"
codesign --verify --deep --strict build/release/check/Holdfast.app || fail "the unpacked app's signature does not verify"
rm -rf build/release/check

commit=$(git rev-parse --short HEAD 2>/dev/null)
[[ -n $(git status --porcelain 2>/dev/null) ]] && commit+=" with uncommitted changes"
print -r -- "Holdfast $version, built from $commit, signed by $(print -r -- "$signature" | sed -n 's/^Authority=//p' | head -1)"
print -r -- "$zip"
shasum -a 256 "$zip" | cut -d ' ' -f 1
