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
    XCTAssertEqual(service.detectLanguage(for: "component.gts"), "typescript")
    XCTAssertEqual(service.detectLanguage(for: "component.gjs"), "typescript")
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
}
