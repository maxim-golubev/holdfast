//
//  main.swift
//  Runs every test. Arguments: -v leaves the app code's output on the terminal; anything else selects the tests
//  whose names contain it.
//

import Foundation

for argument in CommandLine.arguments.dropFirst() {
    if argument == "-v" { Suite.verbose = true } else { Suite.filter = argument }
}
if !Suite.verbose { Suite.captureOutput(in: "build/tests/output.log") }

await micConverterTests()
await logicTests()
await filesTests()
await mixerTests()
await writerTests()
await settingsTests()
await sessionTests()
await statusTests()
Suite.finish()
