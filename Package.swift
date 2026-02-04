// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ASTChunker",
  platforms: [
    .macOS(.v15),
    .iOS(.v18),
  ],
  products: [
    .library(
      name: "ASTChunker",
      targets: ["ASTChunker"]
    ),
    .executable(
      name: "ast-chunker-cli",
      targets: ["ASTChunkerCLI"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-syntax", from: "600.0.0"),
  ],
  targets: [
    .target(
      name: "ASTChunker",
      dependencies: [
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
      ]
    ),
    .testTarget(
      name: "ASTChunkerTests",
      dependencies: ["ASTChunker"]
    ),
    .executableTarget(
      name: "ASTChunkerCLI",
      dependencies: ["ASTChunker"]
    ),
  ]
)
