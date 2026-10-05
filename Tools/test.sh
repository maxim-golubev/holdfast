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
if [[ ! -x $binary || -n $(find $sources Tools/test.sh -newer $binary) ]]; then
  swiftc -Onone -suppress-warnings -swift-version 5 -target arm64-apple-macosx15.0 -o $binary $sources || { echo "TESTS FAILED TO BUILD"; exit 1 }
fi
exec $binary "$@"
