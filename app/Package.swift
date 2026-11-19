// swift-tools-version:5.9
import PackageDescription

// The analysis core (core/, plan step 19): core/build.sh makes core/build.noindex/libbeatkey.a,
// the same universal library the plug-ins link and the parity gate checked. The CBeatKey module
// (Sources/CBeatKey) is its header; this is where the linker finds it.
let coreLibDir = Context.packageDirectory + "/../core/build.noindex"

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
        // Auto-Tune hand-off, the SEND BPM contract, the look's primitives, the chord maths and the MIDI file
        // writer that the MIDI variant uses). plugin/build.sh compiles the
        // same files into each plug-in format under that format's own module name.
        .target(name: "BeatKeyShared", path: "Sources/BeatKeyShared"),
        .systemLibrary(name: "CBeatKey", path: "Sources/CBeatKey"),
        .executableTarget(name: "Orion",
                          dependencies: ["BeatKeyShared", "CBeatKey", .product(name: "Sparkle", package: "Sparkle")],
                          path: "Sources/Orion",
                          resources: [.process("Resources")],
                          // build.sh puts Sparkle.framework in Contents/Frameworks.
                          // ScreenCaptureKit (system audio, macOS 13+) is weak: macOS 12.0-12.2 has none.
                          linkerSettings: [.unsafeFlags(["-L", coreLibDir,
                                                         "-Xlinker", "-rpath",
                                                         "-Xlinker", "@executable_path/../Frameworks",
                                                         "-Xlinker", "-weak_framework",
                                                         "-Xlinker", "ScreenCaptureKit"])]),
        .testTarget(name: "OrionTests", dependencies: ["Orion", "BeatKeyShared", "CBeatKey"], path: "Tests/OrionTests"),
    ]
)
