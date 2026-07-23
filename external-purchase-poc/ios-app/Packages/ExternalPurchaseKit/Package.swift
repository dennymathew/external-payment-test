// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ExternalPurchaseKit",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "ExternalPurchaseKit", targets: ["ExternalPurchaseKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.1")
    ],
    targets: [
        .target(
            name: "ExternalPurchaseKit",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture")
            ]
        ),
        .testTarget(
            name: "ExternalPurchaseKitTests",
            dependencies: ["ExternalPurchaseKit"]
        ),
    ]
)
