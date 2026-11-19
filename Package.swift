// swift-tools-version:5.9
// The Swift version of the LearnMetal Engine, and the Marble sample game.
//
//   swift run Marble             plays the game
//   swift run Editor demo        opens the sample scene in the editor
//   swift run FPV                the drone game, on a Mac (the iPhone app is in the iOS folder)
//   swift test                   runs the unit tests
//
// The code is written for the Swift 5 language mode.
import PackageDescription

let package = Package(
    name: "LearnMetalEngine",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "LMEngine", targets: ["LMEngine"]),
        .executable(name: "Marble", targets: ["Marble"]),
        .executable(name: "Editor", targets: ["Editor"]),
        .library(name: "FPVKit", targets: ["FPVKit"]),
        .executable(name: "FPV", targets: ["FPV"]),
    ],
    targets: [
        // The structs shared with the shaders. The same header is included by the .metal
        // files and by the C++ engine, so the layouts cannot drift apart.
        .target(name: "ShaderTypes", path: "Shaders/Shared", publicHeadersPath: "."),
        .target(name: "LMEngine", dependencies: ["ShaderTypes"], path: "Swift/LMEngine"),
        .executableTarget(name: "Marble", dependencies: ["LMEngine"], path: "Swift/Marble"),
        .executableTarget(name: "Editor", dependencies: ["LMEngine"], path: "Swift/Editor"),
        // FPV, the drone game. The game itself is a library, so that the iPhone app in
        // the iOS folder and the Mac program below are the same code.
        .target(name: "FPVKit", dependencies: ["LMEngine"], path: "Swift/FPVKit"),
        .executableTarget(name: "FPV", dependencies: ["FPVKit", "LMEngine"], path: "Swift/FPV"),
        .testTarget(name: "LMEngineTests", dependencies: ["LMEngine", "ShaderTypes", "FPVKit"], path: "Swift/Tests"),
    ]
)
