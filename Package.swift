// swift-tools-version: 6.0
import PackageDescription
import Foundation

let pngPrefix = ProcessInfo.processInfo.environment["LIBPNG_PREFIX"] ??
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".devkit/dependencies/libpng/install").path

let package = Package(
    name: "EVBShot",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "EVBShot", targets: ["EVBShot"])],
    targets: [
        .target(name: "PixelCore", cSettings: [.unsafeFlags(["-I\(pngPrefix)/include"])],
                linkerSettings: [.unsafeFlags(["\(pngPrefix)/lib/libpng16.a"]), .linkedLibrary("z")]),
        .executableTarget(name: "EVBShot", dependencies: ["PixelCore"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ScreenCaptureKit"),
                             .linkedFramework("AVFoundation"), .linkedFramework("CoreImage")])
    ],
    swiftLanguageModes: [.v5]
)
