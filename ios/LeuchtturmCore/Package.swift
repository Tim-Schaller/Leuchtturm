// swift-tools-version: 6.0
import PackageDescription

// LeuchtturmCore holds everything that is not UI: cryptography, the wire
// protocol and the API client. On Apple platforms it uses CryptoKit only.
// swift-crypto is linked on Linux solely so the core can be tested there.
let package = Package(
    name: "LeuchtturmCore",
    platforms: [.iOS("26.0"), .macOS("15.0"), .tvOS("26.0"), .watchOS("26.0")],
    products: [
        .library(name: "LeuchtturmCore", targets: ["LeuchtturmCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.10.0" ..< "5.0.0"),
    ],
    targets: [
        .target(
            name: "LeuchtturmCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ]
        ),
        .testTarget(
            name: "LeuchtturmCoreTests",
            dependencies: ["LeuchtturmCore"]
        ),
    ]
)
