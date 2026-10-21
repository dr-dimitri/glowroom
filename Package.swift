// swift-tools-version: 5.9
import PackageDescription
import Foundation

// GLOWROOM_DEVELOPER_HARNESS_VERSION: 1
// Developer harnesses compile inside the real app target, so their dependency
// graph cannot drift from production. Only this target receives the flags.
let developerTools = [
    "image-pipeline": "GLOWROOM_IMAGE_PIPELINE_SMOKE",
    "editing": "GLOWROOM_EDITING_BENCHMARK",
    "library": "GLOWROOM_LIBRARY_BENCHMARK",
    "image-generation": "GLOWROOM_IMAGE_GENERATION_EVALUATION"
]
let requestedTool = ProcessInfo.processInfo.environment["GLOWROOM_DEVELOPER_TOOL"]
let toolFlag = requestedTool.flatMap { developerTools[$0] }
if requestedTool != nil && toolFlag == nil {
    fatalError("Unknown GLOWROOM_DEVELOPER_TOOL; use image-pipeline, editing, library or image-generation")
}
var appSettings: [SwiftSetting] = toolFlag.map { [.define("GLOWROOM_DEVELOPER_HARNESS"), .define($0)] } ?? []
if requestedTool == "editing", ProcessInfo.processInfo.environment["GLOWROOM_BENCHMARK_SESSION_API"] == "1" {
    appSettings.append(.define("EDIT_RENDER_SESSIONS"))
}

let package = Package(
    name: "Glowroom",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Glowroom", targets: ["Glowroom"])],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers.git", revision: "e37cacea74498bba66002bb83ecafee3e4ab8884"),
        // Newer Collections condition on compiler 6.4 APIs absent from SDK 26.5.
        // Hub/Jinja use stable OrderedCollections APIs available in this pin.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.2.1")
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "GlowroomCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Glowroom", dependencies: ["GlowroomCore", "CSQLite", .product(name: "Tokenizers", package: "swift-transformers"), .product(name: "Hub", package: "swift-transformers")], resources: [.process("AI/Resources"), .process("Resources")], swiftSettings: appSettings),
        .testTarget(name: "GlowroomCoreTests", dependencies: ["GlowroomCore", "CSQLite"]),
        .testTarget(name: "GlowroomTests", dependencies: ["Glowroom", "GlowroomCore"])
    ]
)
