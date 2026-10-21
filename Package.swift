// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pulse",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7")
    ],
    targets: [
        .executableTarget(
            name: "Pulse",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Pulse"
        )
    ]
)
