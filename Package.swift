// swift-tools-version: 6.1
import PackageDescription

// JSONFoundation — the wire model for JSON, JSON Schema, and JSON-RPC, plus the
// JSON-RPC *runtime* (a transport-agnostic peer and a set of stdio/SSE transports)
// layered into logical, opt-in modules:
//
//   JSONFoundation     value type · JSON Schema · JSON-RPC 2.0 envelope   (pure)
//   JSONRPCPeer        correlation + dispatch over an abstract transport  (pure)
//   JSONRPCWire        framing codecs (Content-Length / line) · SSE decode (pure)
//   JSONRPCStdio       Foundation.Process stdio transport                 (zero-dep)
//   JSONRPCSSE         HTTP+SSE client transport (URLSession)             (zero-dep)
//   JSONRPCSubprocess  swift-subprocess stdio transport                   (trait `Subprocess`)
//
// Everything except `JSONRPCSubprocess` is dependency-free, so the default
// resolution graph stays empty. The one external dependency (swift-subprocess) is
// quarantined behind the `Subprocess` trait, off by default. swift-subprocess
// requires macOS 13, which sets this package's macOS floor.
let package = Package(
    name: "JSONFoundation",
    platforms: [
        .macOS("13.0"),
        .iOS("15.0"),
        .tvOS("15.0"),
        .watchOS("8.0"),
        .macCatalyst("15.0")
    ],
    products: [
        .library(name: "JSONFoundation", targets: ["JSONFoundation"]),
        .library(name: "JSONRPCPeer", targets: ["JSONRPCPeer"]),
        .library(name: "JSONRPCWire", targets: ["JSONRPCWire"]),
        .library(name: "JSONRPCStdio", targets: ["JSONRPCStdio"]),
        .library(name: "JSONRPCSSE", targets: ["JSONRPCSSE"]),
        .library(name: "JSONRPCSubprocess", targets: ["JSONRPCSubprocess"]),
        // Batteries-included, dependency-free bundle: peer + codecs + the two
        // zero-dep transports. Add `JSONRPCSubprocess` + the trait for swift-subprocess.
        .library(name: "JSONRPC", targets: ["JSONRPCPeer", "JSONRPCWire", "JSONRPCStdio", "JSONRPCSSE"])
    ],
    traits: [
        .default(enabledTraits: []),   // base graph: zero external dependencies
        .trait(name: "Subprocess")     // opt-in: the swift-subprocess transport
    ],
    dependencies: [
        // Only resolved when the `Subprocess` trait is enabled (the product below is
        // gated), so the default graph stays dependency-free.
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.5.0")
    ],
    targets: [
        // MARK: Model (pure Foundation, zero dependencies)
        .target(name: "JSONFoundation"),

        // MARK: JSON-RPC runtime (pure — no I/O, no external deps)
        .target(name: "JSONRPCPeer", dependencies: ["JSONFoundation"]),
        .target(name: "JSONRPCWire"),

        // MARK: Transports (do I/O)
        .target(
            name: "JSONRPCStdio",                       // Foundation.Process — zero-dep
            dependencies: ["JSONFoundation", "JSONRPCPeer", "JSONRPCWire"]
        ),
        .target(
            name: "JSONRPCSSE",                         // URLSession — zero external deps
            dependencies: ["JSONFoundation", "JSONRPCPeer", "JSONRPCWire"]
        ),
        .target(
            name: "JSONRPCSubprocess",                  // swift-subprocess — trait-gated
            dependencies: [
                "JSONFoundation", "JSONRPCPeer", "JSONRPCWire",
                .product(name: "Subprocess", package: "swift-subprocess",
                         condition: .when(traits: ["Subprocess"]))
            ]
        ),

        // MARK: Tests
        .testTarget(name: "JSONFoundationTests", dependencies: ["JSONFoundation"]),
        .testTarget(name: "JSONRPCPeerTests", dependencies: ["JSONRPCPeer", "JSONFoundation"]),
        .testTarget(name: "JSONRPCWireTests", dependencies: ["JSONRPCWire"]),
        .testTarget(name: "JSONRPCStdioTests", dependencies: ["JSONRPCStdio", "JSONRPCWire", "JSONFoundation"]),
        .testTarget(name: "JSONRPCSubprocessTests", dependencies: ["JSONRPCSubprocess", "JSONRPCWire", "JSONFoundation"])
    ]
)
