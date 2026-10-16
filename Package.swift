// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PicEdit",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PicEdit", targets: ["PicEdit"])],
    dependencies: [.package(url: "https://github.com/huggingface/swift-transformers.git", revision: "e37cacea74498bba66002bb83ecafee3e4ab8884")],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "PicEditCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "PicEdit", dependencies: ["PicEditCore", "CSQLite", .product(name: "Tokenizers", package: "swift-transformers"), .product(name: "Hub", package: "swift-transformers")], resources: [.process("AI/Resources")]),
        .testTarget(name: "PicEditCoreTests", dependencies: ["PicEditCore", "CSQLite"]),
        .testTarget(name: "PicEditTests", dependencies: ["PicEdit", "PicEditCore"])
    ]
)
