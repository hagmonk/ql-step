// swift-tools-version: 6.0
//
// SwiftPM packaging for the reusable StepPreviewKit library, additive to the
// existing Xcode project. The Xcode build (QuickLookStep.xcodeproj) still drives
// the Quick Look app + extensions and their OCCT dylib bundling; this manifest
// exposes the same StepPreviewKit sources as a SwiftPM library so other Swift
// apps (e.g. zebra-brain's HammondBrowser) can `import StepPreviewKit` and feed
// it in-memory STEP bytes. Links Homebrew OpenCascade directly — intended for
// local builds on a machine with `brew install opencascade`.

import PackageDescription

// Homebrew OpenCascade prefix. Override with OCCT_PREFIX in the environment.
let occtPrefix = Context.environment["OCCT_PREFIX"] ?? "/opt/homebrew/opt/opencascade"

let package = Package(
    name: "StepPreviewKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StepPreviewKit", targets: ["StepPreviewKit"]),
        .executable(name: "StepPreviewBench", targets: ["StepPreviewBench"]),
    ],
    targets: [
        // C++ mesh bridge over OpenCascade (STEPCAFControl/XCAF). Exposes a
        // plain-C ABI (occt_bridge.h) so the Swift side imports it as a C module
        // without C++ interop. Same source + link flags as Makefile:occt-bridge.
        .target(
            name: "COcctBridge",
            path: "occt-bridge",
            exclude: ["bundle-occt.sh", "libocctbridge.dylib"],
            sources: ["occt_bridge.cpp"],
            publicHeadersPath: ".",
            cxxSettings: [
                .unsafeFlags([
                    "-std=c++17",
                    "-I\(occtPrefix)/include/opencascade",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(occtPrefix)/lib",
                    "-lTKDESTEP", "-lTKXCAF", "-lTKMesh", "-lTKBRep",
                    "-lTKernel", "-lTKMath", "-lTKXSBase", "-lTKLCAF",
                    "-lTKCDF", "-lTKTopAlgo", "-lTKG3d", "-lTKDE",
                ]),
            ]
        ),
        // The reusable renderer: STEP bytes/file -> SCNScene, plus the
        // NSViewRepresentable preview view and off-screen thumbnail renderer.
        .target(
            name: "StepPreviewKit",
            dependencies: ["COcctBridge"],
            path: "QuickLookStep/StepPreviewKit"
        ),
        .testTarget(
            name: "StepPreviewKitTests",
            dependencies: ["StepPreviewKit"],
            path: "QuickLookStep/StepPreviewKitTests",
            resources: [.copy("Fixtures")]
        ),
        .executableTarget(
            name: "StepPreviewBench",
            dependencies: ["StepPreviewKit", "COcctBridge"],
            path: "Benchmarks/StepPreviewBench"
        ),
    ]
)
