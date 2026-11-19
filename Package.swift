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
        .executable(name: "gcappy", targets: ["gcappy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        // 端末内での文字起こし（WhisperKit）と話者分離（SpeakerKit）
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ],
    targets: [
        .target(
            name: "CappyKit",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Speech"),
                .linkedFramework("CoreMedia"),
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
        // メニューバーから録音を操作する GUI 版（gcappy.app）。録音そのものは同梱の cappy を子プロセスで動かす
        .executableTarget(
            name: "gcappy",
            dependencies: ["CappyKit"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "CappyKitTests",
            dependencies: ["CappyKit"]
        ),
    ]
)
