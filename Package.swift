// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EVBShot",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "EVBShot", targets: ["EVBShot"])],
    targets: [
        .target(name: "PixelCore", linkerSettings: [.linkedLibrary("z")]),
        .executableTarget(name: "EVBShot", dependencies: ["PixelCore"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ScreenCaptureKit"),
                             .linkedFramework("AVFoundation"), .linkedFramework("CoreImage")])
    ],
    swiftLanguageModes: [.v5]
)
