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
    // Tree-sitter runtime — compiled from source for sandbox compatibility
    .target(
      name: "CTreeSitter",
      path: "Sources/CTreeSitter",
      sources: ["src/lib.c"],
      publicHeadersPath: "include",
      cSettings: [
        .headerSearchPath("src"),
        .define("TREE_SITTER_HIDE_SYMBOLS"),
        .define("TREE_SITTER_NO_WASM"),
      ]
    ),
    // Glimmer TypeScript grammar (parser.c + scanner.c)
    .target(
      name: "CTreeSitterGlimmer",
      dependencies: ["CTreeSitter"],
      path: "Sources/CTreeSitterGlimmer",
      publicHeadersPath: "include",
      cSettings: [
        .headerSearchPath("."),
        .headerSearchPath("tree_sitter"),
      ]
    ),
    .target(
      name: "ASTChunker",
      dependencies: [
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
        "CTreeSitter",
        "CTreeSitterGlimmer",
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
