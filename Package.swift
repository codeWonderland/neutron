// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Neutron",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "neutron", targets: ["neutron"]),
        .library(name: "NeutronCore", targets: ["NeutronCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "neutron",
            dependencies: [
                "NeutronCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(name: "NeutronCore"),
        .testTarget(name: "NeutronCoreTests", dependencies: ["NeutronCore"]),
    ]
)
