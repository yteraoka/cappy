// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Info.plist をバイナリの __TEXT,__info_plist セクションに埋め込む（TCC の利用目的文字列用）
let infoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Support/Info.plist").path

let package = Package(
    name: "cappy",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "cappy", targets: ["cappy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "CappyKit",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "cappy",
            dependencies: [
                "CappyKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlist,
                ]),
            ]
        ),
        .testTarget(
            name: "CappyKitTests",
            dependencies: ["CappyKit"]
        ),
    ]
)
