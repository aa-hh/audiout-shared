// swift-tools-version: 6.0

import PackageDescription

// Three products, deliberately in one package: they are the whole of what the
// Mac app and the iPhone companion share, they are both MIT, and they tend to
// change for the same reason — one end of a pair moving. One repo means one
// tag to bump when that happens. `AudioutField` is the odd one out — its
// consumers aren't the two apps but the brand's several renderers (site, Mac
// app, static card), and it's also readable from plain npm, not just SwiftPM.
//
// iOS 18 is both the companion app's floor and AudioutProtocol's; macOS 14 is
// AudioutCore's. Nothing here should raise either without a reason that
// survives contact with both apps.
let package = Package(
    name: "AudioutShared",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "AudioutProtocol", targets: ["AudioutProtocol"]),
        .library(name: "ProbeKit", targets: ["ProbeKit"]),
        .library(name: "AudioutField", targets: ["AudioutField"]),
    ],
    targets: [
        .target(name: "AudioutProtocol"),
        .testTarget(name: "AudioutProtocolTests", dependencies: ["AudioutProtocol"]),
        .target(name: "ProbeKit"),
        .testTarget(name: "ProbeKitTests", dependencies: ["ProbeKit"]),
        .target(name: "AudioutField", resources: [.process("field.json")]),
        .testTarget(name: "AudioutFieldTests", dependencies: ["AudioutField"]),
    ]
)
