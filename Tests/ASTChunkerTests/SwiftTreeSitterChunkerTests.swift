//
//  SwiftTreeSitterChunkerTests.swift
//  ASTChunkerTests
//
//  Tests for Swift AST chunking using tree-sitter-swift.
//

import XCTest
@testable import ASTChunker

final class SwiftTreeSitterChunkerTests: XCTestCase {

  var chunker: SwiftTreeSitterChunker!
  var treeSitterAvailable: Bool = false

  override func setUp() {
    super.setUp()

    let cliPath = "/opt/homebrew/bin/tree-sitter"
    let libPath = ("~/code/tree-sitter-grammars/tree-sitter-swift/swift.dylib" as NSString).expandingTildeInPath

    treeSitterAvailable = FileManager.default.fileExists(atPath: cliPath) &&
                          FileManager.default.fileExists(atPath: libPath)

    if treeSitterAvailable {
      chunker = SwiftTreeSitterChunker(treeSitterLibPath: libPath, treeSitterCLIPath: cliPath)
    } else {
      chunker = SwiftTreeSitterChunker()
    }
  }

  // MARK: - Basic Tests

  func testLanguageIdentifier() {
    XCTAssertEqual(SwiftTreeSitterChunker.language, "swift")
  }

  func testFileExtensions() {
    XCTAssertTrue(SwiftTreeSitterChunker.handles(extension: "swift"))
    XCTAssertFalse(SwiftTreeSitterChunker.handles(extension: "rb"))
    XCTAssertFalse(SwiftTreeSitterChunker.handles(extension: "ts"))
  }

  func testHandlesFilename() {
    XCTAssertTrue(SwiftTreeSitterChunker.handles(filename: "MyView.swift"))
    XCTAssertFalse(SwiftTreeSitterChunker.handles(filename: "main.rb"))
  }

  func testAvailabilityReflectsDylibPresence() {
    // When no dylib exists at default path, isAvailable should be false
    let unavailable = SwiftTreeSitterChunker(
      treeSitterLibPath: "/nonexistent/path/swift.dylib",
      treeSitterCLIPath: "/opt/homebrew/bin/tree-sitter"
    )
    XCTAssertFalse(unavailable.isAvailable)
  }

  func testFallbackWhenUnavailable() {
    let unavailable = SwiftTreeSitterChunker(
      treeSitterLibPath: "/nonexistent/path/swift.dylib",
      treeSitterCLIPath: "/opt/homebrew/bin/tree-sitter"
    )
    let source = "struct Foo { var x: Int = 0 }"
    let chunks = unavailable.chunk(source: source)
    // Should produce a fallback file chunk
    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks.first?.constructType, .file)
    XCTAssertEqual(chunks.first?.language, "swift")
  }

  // MARK: - Chunking Tests (require tree-sitter-swift dylib)

  func testSimpleStructChunking() throws {
    try skipIfTreeSitterUnavailable()

    let source = """
    struct User {
      let id: UUID
      let name: String
      let email: String
    }
    """

    let chunks = chunker.chunk(source: source, maxChunkLines: 100)

    XCTAssertFalse(chunks.isEmpty)
    for chunk in chunks {
      XCTAssertEqual(chunk.language, "swift")
    }
  }

  func testSimpleClassChunking() throws {
    try skipIfTreeSitterUnavailable()

    let source = """
    class MyViewModel {
      var items: [String] = []

      func loadItems() {
        items = ["a", "b", "c"]
      }
    }
    """

    let chunks = chunker.chunk(source: source, maxChunkLines: 100)

    XCTAssertFalse(chunks.isEmpty)
    let classChunk = chunks.first { $0.constructType == .classDecl }
    XCTAssertNotNil(classChunk)
  }

  func testLargeFileSplitting() throws {
    try skipIfTreeSitterUnavailable()

    var source = "class LargeClass {\n"
    for i in 1...40 {
      source += "  func method\(i)() -> String {\n    return \"method\(i)\"\n  }\n\n"
    }
    source += "}\n"

    let chunks = chunker.chunk(source: source, maxChunkLines: 50)

    // Large class should be split
    XCTAssertGreaterThan(chunks.count, 1)
    for chunk in chunks {
      XCTAssertLessThanOrEqual(chunk.lineCount, 51)
    }
  }

  func testNoStackOverflowOnDeeplyNested() throws {
    try skipIfTreeSitterUnavailable()

    // Generate deeply nested if/else to test iterative parser
    var source = "func deeplyNested() {\n"
    for i in 1...50 {
      source += String(repeating: "  ", count: i) + "if condition\(i) {\n"
    }
    for i in stride(from: 50, through: 1, by: -1) {
      source += String(repeating: "  ", count: i) + "}\n"
    }
    source += "}\n"

    // Should not crash or stack overflow
    let chunks = chunker.chunk(source: source, maxChunkLines: 200)
    XCTAssertFalse(chunks.isEmpty)
  }

  // MARK: - Helpers

  private func skipIfTreeSitterUnavailable() throws {
    if !treeSitterAvailable {
      throw XCTSkip("tree-sitter-swift not available - run Tools/build-tree-sitter-swift.sh to build")
    }
  }
}
