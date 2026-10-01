// swift-tools-version: 6.0
import PackageDescription

// All targets compile in Swift 5 language mode to keep AppKit / IOKit / Network interop pragmatic.
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "OneSwitch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OneSwitch", targets: ["OneSwitchApp"]),
    ],
    targets: [
        // Shared contracts: FeatureModule, settings, logging, hotkeys, permissions, peer-link API.
        .target(name: "OneSwitchCore", swiftSettings: v5),

        // Feature modules (each owns only its own directory).
        .target(name: "Awake", dependencies: ["OneSwitchCore"], swiftSettings: v5),
        // Objective-C shims for private APIs whose exceptions must be caught (Swift cannot catch NSException).
        .target(name: "OneSwitchObjC", linkerSettings: [.linkedFramework("Foundation")]),
        .target(name: "MenuBarHider", dependencies: ["OneSwitchCore", "OneSwitchObjC"], swiftSettings: v5),
        .target(name: "SystemMonitor", dependencies: ["OneSwitchCore"], swiftSettings: v5,
                linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "PeerLink", dependencies: ["OneSwitchCore"], swiftSettings: v5),
        .target(name: "FolderSync", dependencies: ["OneSwitchCore"], swiftSettings: v5),
        .target(name: "SharedInput", dependencies: ["OneSwitchCore"], swiftSettings: v5),

        // The menu-bar app itself.
        .executableTarget(
            name: "OneSwitchApp",
            dependencies: ["OneSwitchCore", "Awake", "MenuBarHider", "SystemMonitor", "PeerLink", "FolderSync", "SharedInput"],
            swiftSettings: v5
        ),

        // Self-check executables (no XCTest with Command Line Tools). Each exits non-zero on failure.
        .executableTarget(name: "AwakeCheck", dependencies: ["OneSwitchCore", "Awake"], path: "Checks/AwakeCheck", swiftSettings: v5),
        .executableTarget(name: "MenuBarHiderCheck", dependencies: ["OneSwitchCore", "MenuBarHider"], path: "Checks/MenuBarHiderCheck", swiftSettings: v5),
        .executableTarget(name: "SystemMonitorCheck", dependencies: ["OneSwitchCore", "SystemMonitor"], path: "Checks/SystemMonitorCheck", swiftSettings: v5),
        .executableTarget(name: "PeerLinkCheck", dependencies: ["OneSwitchCore", "PeerLink"], path: "Checks/PeerLinkCheck", swiftSettings: v5),
        .executableTarget(name: "FolderSyncCheck", dependencies: ["OneSwitchCore", "FolderSync"], path: "Checks/FolderSyncCheck", swiftSettings: v5),
        .executableTarget(name: "SharedInputCheck", dependencies: ["OneSwitchCore", "SharedInput"], path: "Checks/SharedInputCheck", swiftSettings: v5),
        .executableTarget(name: "CoreCheck", dependencies: ["OneSwitchCore"], path: "Checks/CoreCheck", swiftSettings: v5),
    ]
)
