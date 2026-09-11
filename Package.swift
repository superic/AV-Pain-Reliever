// swift-tools-version: 5.10
import PackageDescription

// AV Pain Reliever — Swift Package manifest for the menu-bar app.
//
// `swift run AVPainRelieverApp` from the repo root launches the
// menu-bar agent. `swift test` runs the full test suite. The
// package will eventually be wrapped by an Xcode project for the
// signed-and-notarized .app distribution build, but the SPM
// manifest stays the canonical source of dependencies + targets.
//
// The earlier Hammerspoon-based prototype that this Swift app
// supersedes is archived under `prototypes/hammerspoon/`; see
// `prototypes/README.md` for context.
let package = Package(
    name: "AVPainReliever",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AVPainReliever", targets: ["AVPainReliever"]),
        .executable(name: "AVPainRelieverApp", targets: ["AVPainRelieverApp"]),
        // V2 virtual-camera Camera Extension. Built only when the
        // make-app-with-virtual-camera.sh release script asks for it
        // — the default `make-app.sh` (v0.1.x) doesn't embed it. See
        // docs/virtual-camera.md for the architecture rationale.
        .executable(
            name: "AVPainRelieverCameraExtension",
            targets: ["AVPainRelieverCameraExtension"]
        ),
    ],
    dependencies: [
        // TOML parser. Foundation has JSON/plist but no TOML; locked
        // architectural choice (see docs/decisions.md) is TOML for
        // the human-edited profiles config, so we pick this up.
        // TOMLKit wraps tomlplusplus and exposes a Codable interface.
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.5"),
        // Sparkle 2 — auto-update framework. Reads the EdDSA-signed
        // appcast hosted on GitHub raw, downloads / verifies / installs
        // updates with no server of our own. Only the
        // AVPainRelieverApp target links it; the engine library has
        // no awareness of bundling or updates.
        //
        // Pinned to upToNextMinor because Sparkle is the most
        // notarization-sensitive dependency in the build (its nested
        // Updater.app + XPC services + Autoupdate helper all need to
        // re-sign cleanly inside-out — see scripts/make-app.sh).
        // A new minor could re-shuffle that layout and break our
        // SPARKLE_NESTED list silently. Bumping to a new minor is a
        // deliberate decision, not an automatic Package.resolved
        // refresh.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", .upToNextMinor(from: "2.9.0")),
    ],
    targets: [
        // Pure-Swift constants shared between the host app and the
        // Camera Extension binary. No platform APIs, no third-party
        // deps — keeps the linkage inert so the extension can pull
        // it in without dragging anything else into its sandbox /
        // signing scope. Lives in its own target rather than inside
        // `AVPainReliever` because the extension target deliberately
        // doesn't depend on the engine library.
        .target(
            name: "AVPainRelieverSharedConstants"
        ),
        .target(
            name: "AVPainReliever",
            dependencies: ["TOMLKit"]
        ),
        .executableTarget(
            name: "AVPainRelieverApp",
            dependencies: [
                "AVPainReliever",
                "AVPainRelieverSharedConstants",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(
            name: "AVPainRelieverTests",
            dependencies: ["AVPainReliever"]
        ),
        // Tests for the app target's pure-logic helpers (Theme,
        // ProfileIcon, NotificationCopy, SettingsStore). The view code
        // itself is exercised by hand; this target keeps the
        // map/copy/persist helpers under unit-test coverage.
        .testTarget(
            name: "AVPainRelieverAppTests",
            dependencies: ["AVPainRelieverApp", "AVPainRelieverSharedConstants"]
        ),
        // Camera Extension binary. Imports CoreMediaIO directly; no
        // dependency on AVPainReliever or AVPainRelieverApp — the
        // extension runs in its own process with a clean boundary.
        // Pulls in `AVPainRelieverSharedConstants` so the host and
        // extension can share the Darwin-notification name strings
        // they exchange without hand-mirroring.
        // The compiled binary is wrapped in a .systemextension bundle
        // by scripts/make-app-with-virtual-camera.sh.
        .executableTarget(
            name: "AVPainRelieverCameraExtension",
            dependencies: ["AVPainRelieverSharedConstants"]
        ),
    ]
)
