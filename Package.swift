// swift-tools-version: 5.9
import PackageDescription
import Foundation

// PICEDIT_DEVELOPER_HARNESS_VERSION: 1
// Developer harnesses compile inside the real app target, so their dependency
// graph cannot drift from production. Only this target receives the flags.
let developerTools = [
    "image-pipeline": "PICEDIT_IMAGE_PIPELINE_SMOKE",
    "editing": "PICEDIT_EDITING_BENCHMARK",
    "library": "PICEDIT_LIBRARY_BENCHMARK",
    "image-generation": "PICEDIT_IMAGE_GENERATION_EVALUATION"
]
let requestedTool = ProcessInfo.processInfo.environment["PICEDIT_DEVELOPER_TOOL"]
let toolFlag = requestedTool.flatMap { developerTools[$0] }
if requestedTool != nil && toolFlag == nil {
    fatalError("Unknown PICEDIT_DEVELOPER_TOOL; use image-pipeline, editing, library or image-generation")
}
var appSettings: [SwiftSetting] = toolFlag.map { [.define("PICEDIT_DEVELOPER_HARNESS"), .define($0)] } ?? []
if requestedTool == "editing", ProcessInfo.processInfo.environment["PICEDIT_BENCHMARK_SESSION_API"] == "1" {
    appSettings.append(.define("EDIT_RENDER_SESSIONS"))
}

let package = Package(
    name: "PicEdit",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PicEdit", targets: ["PicEdit"])],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers.git", revision: "e37cacea74498bba66002bb83ecafee3e4ab8884"),
        // Newer Collections condition on compiler 6.4 APIs absent from SDK 26.5.
        // Hub/Jinja use stable OrderedCollections APIs available in this pin.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.2.1")
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "PicEditCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "PicEdit", dependencies: ["PicEditCore", "CSQLite", .product(name: "Tokenizers", package: "swift-transformers"), .product(name: "Hub", package: "swift-transformers")], resources: [.process("AI/Resources")], swiftSettings: appSettings),
        .testTarget(name: "PicEditCoreTests", dependencies: ["PicEditCore", "CSQLite"]),
        .testTarget(name: "PicEditTests", dependencies: ["PicEdit", "PicEditCore"])
    ]
)
