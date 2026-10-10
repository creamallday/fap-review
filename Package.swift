// swift-tools-version:5.9
import PackageDescription

var products: [Product] = [
    .library(name: "ReviewCore", targets: ["ReviewCore"]),
    .executable(name: "review-tool", targets: ["review-tool"]),
]

var targets: [Target] = [
    .target(
        name: "ReviewCore",
        dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]
    ),
    .executableTarget(name: "review-tool", dependencies: ["ReviewCore"]),
    .testTarget(
        name: "ReviewCoreTests",
        dependencies: ["ReviewCore", .product(name: "ZIPFoundation", package: "ZIPFoundation")],
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
// The SwiftUI app only builds on macOS. ReviewCore and its tests also build on Linux.
products.append(.executable(name: "FAPMemoReviewer", targets: ["FAPMemoReviewer"]))
targets.append(.executableTarget(name: "FAPMemoReviewer", dependencies: ["ReviewCore"]))
#endif

let package = Package(
    name: "FAPMemoReviewer",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: targets
)
