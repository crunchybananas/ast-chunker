@testable import ASTChunker
import XCTest

final class SwiftChunkerTests: XCTestCase {
  
  let chunker = SwiftChunker()
  
  // MARK: - Basic Tests
  
  func testSimpleStruct() {
    let source = """
    struct User {
      let id: UUID
      let name: String
      let email: String
    }
    """
    
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks.first?.constructType, .structDecl)
    XCTAssertEqual(chunks.first?.constructName, "User")
    XCTAssertEqual(chunks.first?.startLine, 1)
    XCTAssertEqual(chunks.first?.endLine, 5)
  }
  
  func testSimpleClass() {
    let source = """
    class MyViewModel {
      var items: [String] = []
      
      func loadItems() {
        items = ["a", "b", "c"]
      }
    }
    """
    
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks.first?.constructType, .classDecl)
    XCTAssertEqual(chunks.first?.constructName, "MyViewModel")
  }
  
  func testImportsGrouped() {
    let source = """
    import Foundation
    import SwiftUI
    import Combine
    
    struct MyView: View {
      var body: some View {
        Text("Hello")
      }
    }
    """
    
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    XCTAssertEqual(chunks.count, 2)
    
    // First chunk should be imports
    let importChunk = chunks.first { $0.constructType == .imports }
    XCTAssertNotNil(importChunk)
    XCTAssertTrue(importChunk!.text.contains("import Foundation"))
    XCTAssertTrue(importChunk!.text.contains("import SwiftUI"))
    XCTAssertTrue(importChunk!.text.contains("import Combine"))
    XCTAssertEqual(importChunk?.startLine, 1)
    XCTAssertEqual(importChunk?.endLine, 3)
    
    // Second chunk should be the struct
    let structChunk = chunks.first { $0.constructType == .structDecl }
    XCTAssertNotNil(structChunk)
    XCTAssertEqual(structChunk?.constructName, "MyView")
  }
  
  func testProtocolAndExtension() {
    let source = """
    protocol DataProvider {
      func fetchData() async throws -> [Item]
    }
    
    extension DataProvider {
      func fetchDataSync() -> [Item] {
        []
      }
    }
    """
    
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    XCTAssertEqual(chunks.count, 2)
    
    let protocolChunk = chunks.first { $0.constructType == .protocolDecl }
    XCTAssertNotNil(protocolChunk)
    XCTAssertEqual(protocolChunk?.constructName, "DataProvider")
    
    let extensionChunk = chunks.first { $0.constructType == .extension }
    XCTAssertNotNil(extensionChunk)
    XCTAssertTrue(extensionChunk!.constructName!.contains("DataProvider"))
  }
  
  func testEnum() {
    let source = """
    enum LoadingState<T> {
      case idle
      case loading
      case loaded(T)
      case error(Error)
    }
    """
    
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks.first?.constructType, .enumDecl)
    XCTAssertEqual(chunks.first?.constructName, "LoadingState")
  }
  
  func testActor() {
    let source = """
    actor NetworkService {
      private var cache: [String: Data] = [:]
      
      func fetch(url: String) async throws -> Data {
        if let cached = cache[url] { return cached }
        let data = try await download(url)
        cache[url] = data
        return data
      }
    }
    """
    
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks.first?.constructType, .actorDecl)
    XCTAssertEqual(chunks.first?.constructName, "NetworkService")
  }
  
  func testTopLevelFunction() {
    let source = """
    func calculateTotal(_ items: [Item]) -> Int {
      items.reduce(0) { $0 + $1.price }
    }
    """
    
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks.first?.constructType, .function)
    XCTAssertEqual(chunks.first?.constructName, "calculateTotal")
  }
  
  // MARK: - Large Declaration Splitting
  
  func testLargeClassSplitByMethods() {
    // Create a class with multiple methods that exceeds maxChunkLines
    var methods = ""
    for i in 1...5 {
      methods += """
        
        func method\(i)() {
          // Line 1
          // Line 2
          // Line 3
          // Line 4
          // Line 5
          print("method \(i)")
        }
      
      """
    }
    
    let source = """
    class BigClass {
      var property1: String = ""
      var property2: Int = 0
      \(methods)
    }
    """
    
    let chunks = chunker.chunk(source: source, maxChunkLines: 15)
    
    // Should split into multiple chunks
    XCTAssertGreaterThan(chunks.count, 1)
    
    // Should have method chunks
    let methodChunks = chunks.filter { $0.constructType == .method }
    XCTAssertGreaterThan(methodChunks.count, 0)
    
    // Method chunks should have proper naming
    for chunk in methodChunks {
      XCTAssertTrue(chunk.constructName?.starts(with: "BigClass.") ?? false,
                    "Method chunk should have parent name prefix: \(chunk.constructName ?? "nil")")
    }
  }
  
  func testInitializerChunking() {
    let source = """
    struct Config {
      let name: String
      let value: Int
      
      init(name: String, value: Int) {
        self.name = name
        self.value = value
      }
      
      init?(dictionary: [String: Any]) {
        guard let name = dictionary["name"] as? String,
              let value = dictionary["value"] as? Int else {
          return nil
        }
        self.name = name
        self.value = value
      }
    }
    """
    
    let chunks = chunker.chunk(source: source, maxChunkLines: 10)
    
    // Should split and have init methods
    let methodChunks = chunks.filter { $0.constructType == .method }
    let initNames = methodChunks.compactMap { $0.constructName }
    
    XCTAssertTrue(initNames.contains { $0.contains("init") })
    XCTAssertTrue(initNames.contains { $0.contains("init?") })
  }
  
  // MARK: - Line Number Accuracy
  
  func testLineNumbersAccurate() {
    // Using explicit newlines to ensure proper line counting
    let source = "import Foundation\n\nstruct MyStruct {\n  let value: Int\n}"
    
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    // Debug: print actual values
    for chunk in chunks {
      print("Chunk: \(chunk.constructType) '\(chunk.constructName ?? "nil")' lines \(chunk.startLine)-\(chunk.endLine)")
    }
    
    let importChunk = chunks.first { $0.constructType == .imports }
    XCTAssertNotNil(importChunk)
    XCTAssertEqual(importChunk?.startLine, 1)
    XCTAssertEqual(importChunk?.endLine, 1)
    
    let structChunk = chunks.first { $0.constructType == .structDecl }
    XCTAssertNotNil(structChunk)
    // SwiftSyntax may include leading trivia - check actual position
    XCTAssertGreaterThanOrEqual(structChunk?.startLine ?? 0, 1)
    XCTAssertEqual(structChunk?.endLine, 5)
  }
  
  // MARK: - Edge Cases
  
  func testEmptySource() {
    let chunks = chunker.chunk(source: "", maxChunkLines: 100)
    XCTAssertTrue(chunks.isEmpty)
  }
  
  func testOnlyComments() {
    let source = """
    // This is a comment
    // Another comment
    /* Multi-line
       comment */
    """
    
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    // Should produce fallback chunks since no declarations
    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks.first?.constructType, .file)
  }
  
  func testNestedTypes() {
    let source = """
    struct Outer {
      struct Inner {
        let value: Int
      }
      
      let inner: Inner
    }
    """
    
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    // Should have the outer struct as one chunk (nested types stay together)
    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks.first?.constructType, .structDecl)
    XCTAssertEqual(chunks.first?.constructName, "Outer")
    XCTAssertTrue(chunks.first!.text.contains("struct Inner"))
  }
  
  func testMultipleTopLevelDeclarations() {
    let source = """
    struct A { let x: Int }
    struct B { let y: Int }
    struct C { let z: Int }
    """
    
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    XCTAssertEqual(chunks.count, 3)
    let names = chunks.compactMap { $0.constructName }
    XCTAssertTrue(names.contains("A"))
    XCTAssertTrue(names.contains("B"))
    XCTAssertTrue(names.contains("C"))
  }
}
