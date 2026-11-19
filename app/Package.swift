// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Orion",
    platforms: [.macOS(.v12)],
    dependencies: [
        // App updates (Beat Key › Check for Updates…, Run Doctor). Pinned: build.sh embeds and
        // re-signs this exact framework, and uses its bin/ tools for the appcast.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Swift the app and the plug-in's face both compile (key names, tempo text, tuning maths, the
        // Auto-Tune hand-off, the SEND BPM contract, the look's primitives). plugin/build.sh compiles the
        // same files into each plug-in format under that format's own module name.
        .target(name: "BeatKeyShared", path: "Sources/BeatKeyShared"),
        .executableTarget(name: "Orion",
                          dependencies: ["BeatKeyShared", .product(name: "Sparkle", package: "Sparkle")],
                          path: "Sources/Orion",
                          resources: [.process("Resources")],
                          // build.sh puts Sparkle.framework in Contents/Frameworks.
                          // ScreenCaptureKit (system audio, macOS 13+) is weak: macOS 12.0-12.2 has none.
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath",
                                                         "-Xlinker", "@executable_path/../Frameworks",
                                                         "-Xlinker", "-weak_framework",
                                                         "-Xlinker", "ScreenCaptureKit"])]),
        .testTarget(name: "OrionTests", dependencies: ["Orion", "BeatKeyShared"], path: "Tests/OrionTests"),
    ]
)
