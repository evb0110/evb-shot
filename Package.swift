// swift-tools-version: 6.0
import PackageDescription
import Foundation

let pngPrefix = ProcessInfo.processInfo.environment["LIBPNG_PREFIX"] ??
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".devkit/dependencies/libpng/install").path

let package = Package(
    name: "EVBShot",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "EVBShot", targets: ["EVBShot"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "PixelCore", cSettings: [.unsafeFlags(["-I\(pngPrefix)/include"])],
                linkerSettings: [.unsafeFlags(["\(pngPrefix)/lib/libpng16.a"]), .linkedLibrary("z")]),
        .executableTarget(name: "EVBShot", dependencies: ["PixelCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ScreenCaptureKit"),
                             .linkedFramework("AVFoundation"), .linkedFramework("CoreImage"), .linkedFramework("CoreAudio"),
                             .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])])
    ],
    swiftLanguageModes: [.v5]
)
