// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "SonoraNative",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "SonoraCore", targets: ["SonoraCore"]), .executable(name: "NativeSmoke", targets: ["NativeSmoke"])],
    dependencies: [.package(url: "https://github.com/alexeichhorn/YouTubeKit.git", exact: "0.4.10")],
    targets: [
        .target(name: "SonoraCore", dependencies: [.product(name: "YouTubeKit", package: "YouTubeKit")], path: ".", exclude: ["App.swift", "CoreTests.swift", "Smoke.swift", "GenerateIcon.swift", "project.yml", "README.md", "YouTubeKit-LICENSE.txt"], sources: ["Core.swift"]),
        .testTarget(name: "SonoraCoreTests", dependencies: ["SonoraCore"], path: ".", sources: ["CoreTests.swift"]),
        .executableTarget(name: "NativeSmoke", dependencies: ["SonoraCore"], path: ".", sources: ["Smoke.swift"])
    ]
)
