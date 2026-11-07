// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacOSNativeTouch",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "TouchInjector", targets: ["TouchInjector"]),
        .executable(name: "TouchObserver", targets: ["TouchObserver"]),
    ],
    targets: [
        .target(name: "TouchFormat"),
        .executableTarget(name: "TouchInjector", dependencies: ["TouchFormat"]),
        .target(name: "TouchObserverState"),
        .executableTarget(name: "TouchObserver", dependencies: ["TouchObserverState"]),
        .testTarget(name: "TouchFormatTests", dependencies: ["TouchFormat"]),
        .testTarget(name: "TouchObserverTests", dependencies: ["TouchObserverState"]),
    ]
)
