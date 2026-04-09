@testable import ASTChunker
import XCTest

final class ASTChunkerTests: XCTestCase {
  
  // MARK: - Swift Chunker Tests
  
  func testSwiftClassChunking() throws {
    let source = """
    import Foundation
    import SwiftUI
    
    class MyViewModel: ObservableObject {
      @Published var items: [String] = []
      
      func loadItems() {
        items = ["a", "b", "c"]
      }
      
      func addItem(_ item: String) {
        items.append(item)
      }
    }
    """
    
    let chunker = SwiftChunker()
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    // Should have: imports + class
    XCTAssertGreaterThanOrEqual(chunks.count, 2)
    
    // First chunk should be imports
    let importChunk = chunks.first { $0.constructType == .imports }
    XCTAssertNotNil(importChunk)
    XCTAssertTrue(importChunk!.text.contains("import Foundation"))
    
    // Should have the class
    let classChunk = chunks.first { $0.constructType == .classDecl }
    XCTAssertNotNil(classChunk)
    XCTAssertEqual(classChunk?.constructName, "MyViewModel")
  }
  
  func testSwiftStructChunking() throws {
    let source = """
    struct User: Codable {
      let id: UUID
      let name: String
      let email: String
    }
    """
    
    let chunker = SwiftChunker()
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks.first?.constructType, .structDecl)
    XCTAssertEqual(chunks.first?.constructName, "User")
  }
  
  func testSwiftProtocolAndExtension() throws {
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
    
    let chunker = SwiftChunker()
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    XCTAssertEqual(chunks.count, 2)
    
    let protocolChunk = chunks.first { $0.constructType == .protocolDecl }
    XCTAssertNotNil(protocolChunk)
    XCTAssertEqual(protocolChunk?.constructName, "DataProvider")
    
    let extensionChunk = chunks.first { $0.constructType == .extension }
    XCTAssertNotNil(extensionChunk)
    XCTAssertTrue(extensionChunk!.constructName?.contains("DataProvider") ?? false)
  }
  
  // MARK: - Ruby Chunker Tests
  
  func testRubyClassChunking() throws {
    let source = """
    # frozen_string_literal: true
    
    class UserService
      def initialize(repository)
        @repository = repository
      end
    
      def find_user(id)
        @repository.find(id)
      end
    
      def create_user(params)
        @repository.create(params)
      end
    end
    """
    
    let chunker = RubyChunker()
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    XCTAssertGreaterThanOrEqual(chunks.count, 1)
    
    let classChunk = chunks.first { $0.constructType == .classDecl }
    XCTAssertNotNil(classChunk)
    XCTAssertEqual(classChunk?.constructName, "UserService")
  }
  
  func testRubyModuleChunking() throws {
    let source = """
    module Authentication
      def authenticate(token)
        validate_token(token)
      end
    
      private
    
      def validate_token(token)
        token.present?
      end
    end
    """
    
    let chunker = RubyChunker()
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    XCTAssertGreaterThanOrEqual(chunks.count, 1)
    
    let moduleChunk = chunks.first { $0.constructType == .module }
    XCTAssertNotNil(moduleChunk)
    XCTAssertEqual(moduleChunk?.constructName, "Authentication")
  }
  
  // MARK: - TypeScript Chunker Tests (Placeholder - Not Yet Implemented)
  
  func testTypeScriptClassChunking() throws {
    // TypeScriptChunker not yet implemented - skip for now
    throw XCTSkip("TypeScriptChunker not yet implemented - see issue #173")
  }
  
  func testTypeScriptFunctionChunking() throws {
    // TypeScriptChunker not yet implemented - skip for now
    throw XCTSkip("TypeScriptChunker not yet implemented - see issue #173")
  }
  
  func testTypeScriptInterfaceChunking() throws {
    // TypeScriptChunker not yet implemented - skip for now
    throw XCTSkip("TypeScriptChunker not yet implemented - see issue #173")
  }
  
  // MARK: - ASTChunkerService Tests
  
  func testServiceLanguageDetection() {
    let service = ASTChunkerService()
    
    // Swift files
    XCTAssertEqual(service.detectLanguage(for: "MyClass.swift"), "swift")
    
    // Ruby files
    XCTAssertEqual(service.detectLanguage(for: "user_service.rb"), "ruby")
    XCTAssertEqual(service.detectLanguage(for: "Gemfile"), "ruby")
    XCTAssertEqual(service.detectLanguage(for: "Rakefile"), "ruby")
    
    // TypeScript files
    XCTAssertEqual(service.detectLanguage(for: "component.ts"), "typescript")
    XCTAssertEqual(service.detectLanguage(for: "component.tsx"), "typescript")
    XCTAssertEqual(service.detectLanguage(for: "component.gts"), "gts")
    XCTAssertEqual(service.detectLanguage(for: "component.gjs"), "gjs")
    XCTAssertEqual(service.detectLanguage(for: "helper.js"), "typescript")
  }
  
  func testServiceChunking() {
    let service = ASTChunkerService()
    
    let swiftSource = """
    struct Point {
      let x: Int
      let y: Int
    }
    """
    
    let chunks = service.chunk(source: swiftSource, filename: "Point.swift", maxChunkLines: 50)
    
    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks.first?.language, "swift")
    XCTAssertEqual(chunks.first?.constructType, .structDecl)
  }
  
  func testFallbackChunking() {
    let service = ASTChunkerService()
    
    let unknownSource = """
    This is some text content
    that doesn't have any recognizable
    programming language syntax.
    It should fall back to basic chunking.
    """
    
    let chunks = service.chunk(source: unknownSource, filename: "notes.txt", maxChunkLines: 2)
    
    // Should produce fallback chunks
    XCTAssertGreaterThan(chunks.count, 1)
    XCTAssertEqual(chunks.first?.constructType, .file)
  }

  func testServiceUsesJSCoreForTypeScriptWhenAvailable() throws {
    let jsCore = JSCoreTypeScriptChunker.shared
    try XCTSkipUnless(jsCore.isAvailable, "JSCore TypeScript chunker not available: \(jsCore.initError ?? \"unknown\")")

    let service = ASTChunkerService()
    let source = """
    export class UserService {
      private users: User[] = [];
    }
    """

    let chunks = service.chunk(source: source, filename: "UserService.ts", maxChunkLines: 100)
    let classChunk = try XCTUnwrap(chunks.first { $0.constructType == .classDecl })

    XCTAssertEqual(classChunk.constructName, "UserService")
    XCTAssertTrue(classChunk.metadata.symbolReferences.contains(ASTSymbol(name: "User", kind: .unknown, language: "typescript")))
  }

  func testServiceSupportsGTSViaAvailableParser() throws {
    let jsCore = JSCoreTypeScriptChunker.shared
    let glimmer = GlimmerChunker()
    try XCTSkipUnless(jsCore.isAvailable || glimmer.isAvailable, "No GTS-capable parser available")

    let service = ASTChunkerService()
    let source = """
    import Component from '@glimmer/component';

    export default class Greeting extends Component {
      <template>
        Hello
      </template>
    }
    """

    let chunks = service.chunk(source: source, filename: "Greeting.gts", maxChunkLines: 100)
    let classChunk = try XCTUnwrap(chunks.first { $0.constructType == .classDecl })

    XCTAssertEqual(classChunk.constructName, "Greeting")
    XCTAssertTrue(classChunk.text.contains("<template>"))
  }

  // MARK: - Symbol Metadata Tests

  func testChunkInitializerNormalizesDefinitionAndReferenceSymbols() {
    let chunk = ASTChunk(
      constructType: .classDecl,
      constructName: "UserService",
      startLine: 1,
      endLine: 10,
      text: "class UserService { let repository: UserRepository }",
      language: "swift",
      metadata: ASTChunkMetadata(typeReferences: ["UserRepository", "User"])
    )

    XCTAssertEqual(chunk.metadata.symbolDefinitions, [
      ASTSymbol(name: "UserService", kind: .type, language: "swift")
    ])
    XCTAssertEqual(chunk.metadata.symbolReferences, [
      ASTSymbol(name: "UserRepository", kind: .unknown, language: "swift"),
      ASTSymbol(name: "User", kind: .unknown, language: "swift")
    ])
  }

  func testChunkMetadataDecodesLegacyJSONWithoutSymbolFields() throws {
    let json = #"{"decorators":["@MainActor"],"typeReferences":["Repository"]}"#

    let metadata = try XCTUnwrap(ASTChunkMetadata.fromJSON(json))

    XCTAssertEqual(metadata.decorators, ["@MainActor"])
    XCTAssertEqual(metadata.typeReferences, ["Repository"])
    XCTAssertTrue(metadata.symbolDefinitions.isEmpty)
    XCTAssertTrue(metadata.symbolReferences.isEmpty)
  }
}
