// Paths.swift
// Where the engine finds its Shaders and Assets folders.
//
// While developing, both are read straight from the source tree, so a shader can be
// edited and reloaded without rebuilding anything. The location is, in order:
//   1. the directory in the LM_ROOT environment variable,
//   2. a folder next to the executable that contains "Shaders" (a packaged game),
//   3. the source tree this binary was built from.

import Foundation

/// The directory that contains Shaders/ and Assets/.
public func findRootDirectory() -> String {
    if let fromEnvironment = ProcessInfo.processInfo.environment["LM_ROOT"] {
        return fromEnvironment
    }
    if let executable = Bundle.main.executableURL {
        let beside = executable.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: beside.appendingPathComponent("Shaders").path) {
            return beside.path
        }
    }
    // #filePath is this file's location when it was compiled:
    // <root>/Swift/LMEngine/Core/Paths.swift, four levels below the root.
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { root.deleteLastPathComponent() }
    return root.path
}
