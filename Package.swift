// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotesToWeb",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "NotesToWebKit", targets: ["NotesToWebKit"]),
        .executable(name: "NotesToWeb", targets: ["NotesToWeb"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "NotesToWebKit",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "NotesToWeb",
            dependencies: ["NotesToWebKit"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "NotesToWebKitTests",
            dependencies: ["NotesToWebKit"]
        ),
    ]
)
