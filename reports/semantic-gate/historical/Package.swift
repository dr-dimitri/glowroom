// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "SemanticFP32Gate", platforms:[.macOS(.v14)], dependencies:[
 .package(url:"https://github.com/huggingface/swift-transformers.git",revision:"e37cacea74498bba66002bb83ecafee3e4ab8884")
],targets:[.executableTarget(name:"SemanticFP32Gate",dependencies:[.product(name:"Tokenizers",package:"swift-transformers")])])
