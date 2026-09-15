// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AwakenedPoeTradeNative",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AwakenedPoeTrade", targets: ["AwakenedPoeTrade"]),
        .library(name: "TradeCore", targets: ["TradeCore"])
    ],
    targets: [
        .target(name: "TradeCore", resources: [.copy("Resources/trade-core.js")]),
        .executableTarget(name: "AwakenedPoeTrade", dependencies: ["TradeCore"]),
        .testTarget(name: "TradeCoreTests", dependencies: ["TradeCore"])
    ],
    swiftLanguageModes: [.v5]
)
