// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Hush",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Hush", targets: ["Hush"])],
    targets: [
        .executableTarget(name: "Hush"),
        .testTarget(name: "HushTests", dependencies: ["Hush"])
    ]
)
