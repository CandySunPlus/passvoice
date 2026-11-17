// swift-tools-version: 5.9

import Foundation
import PackageDescription

let helperPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/PassportHelper/HelperInfo.plist").path

let package = Package(
    name: "PassVoice",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "passvoice", targets: ["PassVoice"]),
        .executable(name: "passport-helper", targets: ["PassportHelper"]),
    ],
    targets: [
        .executableTarget(name: "PassVoice"),
        .executableTarget(
            name: "PassportHelper",
            exclude: ["HelperInfo.plist", "LICENSE"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist", "-Xlinker", helperPlist,
            ])]
        ),
    ]
)
