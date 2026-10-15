// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PicEdit",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PicEdit", targets: ["PicEdit"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "PicEditCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "PicEdit", dependencies: ["PicEditCore"]),
        .testTarget(name: "PicEditCoreTests", dependencies: ["PicEditCore", "CSQLite"]),
        .testTarget(name: "PicEditTests", dependencies: ["PicEdit", "PicEditCore"])
    ]
)
