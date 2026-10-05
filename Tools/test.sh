#!/bin/zsh
# Tests the pure logic of the recording pipeline: compiles the app sources listed below together with Tests/*.swift
# into build/tests and runs them. Nothing is launched, captured or recorded. Prints one line per test and a
# summary; exits non-zero when the build or any test fails. What the app code prints goes to build/tests/output.log.
# Usage: Tools/test.sh [-v] [word in the test names to run]
cd "$(dirname "$0")/.."
sources=(
  QuickRecorder/MicConverter.swift
  QuickRecorder/RecordingLogic.swift
  QuickRecorder/RecordingMixer.swift
  QuickRecorder/Supports/DiskSpace.swift
  Tests/*.swift
)
mkdir -p build/tests
binary=build/tests/tests
# Rebuilt when a source is newer than the binary or the list of sources is not the one it was built from
# (a test file that was removed or renamed must not keep running from the old binary)
if [[ ! -x $binary || "$(<$binary.sources)" != "$sources" || -n $(find $sources Tools/test.sh -newer $binary) ]] 2>/dev/null; then
  rm -f $binary $binary.sources
  swiftc -Onone -suppress-warnings -swift-version 5 -target arm64-apple-macosx15.0 -o $binary $sources || { echo "TESTS FAILED TO BUILD"; exit 1 }
  print -r -- "$sources" > $binary.sources
fi
exec $binary "$@"
