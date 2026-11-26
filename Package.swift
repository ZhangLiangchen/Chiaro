// swift-tools-version: 6.0
import PackageDescription
import Foundation

let cltTestingPluginDir = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSwiftSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: cltTestingPluginDir)
    ? [.unsafeFlags(["-plugin-path", cltTestingPluginDir])]
    : []

let package = Package(
    name: "Chiaro",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ChiaroCore", targets: ["ChiaroCore"]),
        .library(name: "ChiaroAppCore", targets: ["ChiaroAppCore"]),
        .executable(name: "chiaro-cli", targets: ["ChiaroCLI"]),
        .executable(name: "Chiaro", targets: ["ChiaroApp"]),
    ],
    targets: [
        .binaryTarget(
            name: "LibRaw",
            path: "Vendor/XCFrameworks/LibRaw.xcframework"
        ),
        .binaryTarget(
            name: "LibRTProcess",
            path: "Vendor/XCFrameworks/LibRTProcess.xcframework"
        ),
        .binaryTarget(
            name: "LibLensfun",
            path: "Vendor/XCFrameworks/LibLensfun.xcframework"
        ),
        .binaryTarget(
            name: "LibUltraHDR",
            path: "Vendor/XCFrameworks/LibUltraHDR.xcframework"
        ),
        .binaryTarget(
            name: "LibAVIF",
            path: "Vendor/XCFrameworks/LibAVIF.xcframework"
        ),

        .target(
            name: "CLibRawBridge",
            dependencies: ["LibRaw", "LibRTProcess"],
            path: "Sources/CLibRawBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-std=c++17"]),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedLibrary("m"),
            ]
        ),
        .target(
            name: "CLensfunBridge",
            dependencies: ["LibLensfun"],
            path: "Sources/CLensfunBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .define("CONF_LENSFUN_STATIC"),
                .unsafeFlags(["-std=c++17"]),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("m"),
                .linkedLibrary("iconv"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreFoundation"),
                .unsafeFlags([
                    "/opt/homebrew/opt/glib/lib/libglib-2.0.a",
                    "/opt/homebrew/opt/gettext/lib/libintl.a",
                    "/opt/homebrew/opt/pcre2/lib/libpcre2-8.a",
                ]),
            ]
        ),
        .target(
            name: "CUltraHDRBridge",
            dependencies: ["LibUltraHDR"],
            path: "Sources/CUltraHDRBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-std=c++17"]),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("m"),
                .unsafeFlags(["/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.a"]),
            ]
        ),
        .target(
            name: "CLibAVIFBridge",
            dependencies: ["LibAVIF"],
            path: "Sources/CLibAVIFBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("m"),
                .unsafeFlags([
                    "-L/opt/homebrew/opt/svt-av1/lib", "-lSvtAv1Enc",
                    "-L/opt/homebrew/opt/aom/lib", "-laom",
                    "-L/opt/homebrew/opt/dav1d/lib", "-ldav1d",
                ]),
            ]
        ),

        .target(
            name: "ChiaroCore",
            dependencies: [
                "CLibRawBridge",
                "CLensfunBridge",
                "CUltraHDRBridge",
                "CLibAVIFBridge",
            ],
            path: "Sources/ChiaroCore",
            resources: [
                .copy("ColorMetal/Shaders.metal"),
                .copy("../../Presets"),
                .copy("Resources/LensfunDB"),
                .copy("Resources/NoiseProfiles"),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .target(
            name: "ChiaroAppCore",
            dependencies: ["ChiaroCore"],
            path: "Sources/ChiaroAppCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .executableTarget(
            name: "ChiaroCLI",
            dependencies: ["ChiaroCore"],
            path: "Sources/ChiaroCLI"
        ),
        .executableTarget(
            name: "ChiaroApp",
            dependencies: ["ChiaroCore", "ChiaroAppCore"],
            path: "App",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Metal"),
            ]
        ),
        .testTarget(
            name: "ChiaroCoreTests",
            dependencies: ["ChiaroCore", "ChiaroAppCore"],
            path: "Tests/ChiaroCoreTests",
            swiftSettings: testSwiftSettings
        ),
    ],
    cxxLanguageStandard: .cxx17
)
