// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacOSNativeTouch",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "TouchInjector", targets: ["TouchInjector"])],
    targets: [
        .target(name: "TouchFormat"),
        .executableTarget(name: "TouchInjector", dependencies: ["TouchFormat"]),
        .testTarget(name: "TouchFormatTests", dependencies: ["TouchFormat"]),
    ]
)
