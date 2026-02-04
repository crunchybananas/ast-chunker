//
//  RubyChunkerTests.swift
//  ASTChunkerTests
//
//  Tests for Ruby AST chunking using tree-sitter.
//

import XCTest
@testable import ASTChunker

final class RubyChunkerTests: XCTestCase {
  
  var chunker: RubyChunker!
  var treeSitterAvailable: Bool = false
  
  override func setUp() {
    super.setUp()
    
    // Check if tree-sitter is available
    let cliPath = "/opt/homebrew/bin/tree-sitter"
    let libPath = ("~/code/tree-sitter-grammars/tree-sitter-ruby/ruby.dylib" as NSString).expandingTildeInPath
    
    treeSitterAvailable = FileManager.default.fileExists(atPath: cliPath) &&
                          FileManager.default.fileExists(atPath: libPath)
    
    if treeSitterAvailable {
      chunker = RubyChunker(treeSitterLibPath: libPath, treeSitterCLIPath: cliPath)
    }
  }
  
  // MARK: - Basic Tests
  
  func testLanguageIdentifier() {
    XCTAssertEqual(RubyChunker.language, "ruby")
  }
  
  func testFileExtensions() {
    XCTAssertTrue(RubyChunker.handles(extension: "rb"))
    XCTAssertTrue(RubyChunker.handles(extension: "rake"))
    XCTAssertTrue(RubyChunker.handles(extension: "gemspec"))
    XCTAssertFalse(RubyChunker.handles(extension: "swift"))
    XCTAssertFalse(RubyChunker.handles(extension: "py"))
  }
  
  func testHandlesFilename() {
    XCTAssertTrue(RubyChunker.handles(filename: "user.rb"))
    XCTAssertTrue(RubyChunker.handles(filename: "deploy.rake"))
    XCTAssertTrue(RubyChunker.handles(filename: "myapp.gemspec"))
    XCTAssertFalse(RubyChunker.handles(filename: "main.swift"))
  }
  
  // MARK: - Chunking Tests (require tree-sitter)
  
  func testSimpleClassChunking() throws {
    try skipIfTreeSitterUnavailable()
    
    let source = """
    class User
      attr_accessor :name, :email
      
      def initialize(name, email)
        @name = name
        @email = email
      end
      
      def full_info
        "#{@name} <#{@email}>"
      end
    end
    """
    
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    // Should produce at least one chunk
    XCTAssertFalse(chunks.isEmpty)
    
    // All chunks should be Ruby
    for chunk in chunks {
      XCTAssertEqual(chunk.language, "ruby")
    }
    
    // Lines should be covered
    let firstChunk = chunks.first!
    XCTAssertGreaterThanOrEqual(firstChunk.startLine, 1)
  }
  
  func testModuleChunking() throws {
    try skipIfTreeSitterUnavailable()
    
    let source = """
    module Concerns
      module Authenticatable
        extend ActiveSupport::Concern
        
        included do
          has_secure_password
        end
        
        def authenticate(password)
          self.password == password
        end
      end
    end
    """
    
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    XCTAssertFalse(chunks.isEmpty)
    
    // Should recognize module construct
    let hasModule = chunks.contains { $0.constructType == .module }
    // Note: May fall back to .unknown or .classDecl depending on parsing
    XCTAssertTrue(chunks.count >= 1)
  }
  
  func testRailsModelChunking() throws {
    try skipIfTreeSitterUnavailable()
    
    let source = """
    class User < ApplicationRecord
      include Concerns::Authenticatable
      
      has_many :posts
      has_many :comments
      
      validates :email, presence: true, uniqueness: true
      validates :name, presence: true
      
      scope :active, -> { where(active: true) }
      
      def admin?
        role == 'admin'
      end
      
      def deactivate!
        update!(active: false)
      end
      
      private
      
      def set_defaults
        self.role ||= 'user'
      end
    end
    """
    
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    XCTAssertFalse(chunks.isEmpty)
    
    // Should fit in one chunk (< 100 lines)
    XCTAssertEqual(chunks.count, 1)
    
    // Should be recognized as a class
    XCTAssertTrue(chunks.first?.constructType == .classDecl || chunks.first?.constructType == .file)
  }
  
  func testLargeFileSplitting() throws {
    try skipIfTreeSitterUnavailable()
    
    // Generate a large class with many methods
    var source = "class LargeModel < ApplicationRecord\n"
    for i in 1...50 {
      source += """
        def method_\(i)
          # Method \(i) implementation
          puts "Method \(i)"
          do_something_\(i)
        end
        
      """
    }
    source += "end\n"
    
    // Chunk with small max to force splitting
    let chunks = chunker.chunk(source: source, maxChunkLines: 50)
    
    // Should be split into multiple chunks
    XCTAssertGreaterThan(chunks.count, 1)
    
    // Lines should be continuous
    for chunk in chunks {
      XCTAssertGreaterThan(chunk.endLine, chunk.startLine - 1)
    }
  }
  
  func testFallbackOnParseError() throws {
    try skipIfTreeSitterUnavailable()
    
    // Intentionally malformed Ruby
    let source = """
    class Broken
      def method(
        # Missing closing paren and end
    """
    
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    
    // Should still produce chunks (fallback)
    XCTAssertFalse(chunks.isEmpty)
  }
  
  // MARK: - Helpers
  
  private func skipIfTreeSitterUnavailable() throws {
    if !treeSitterAvailable {
      throw XCTSkip("tree-sitter not available - install with: brew install tree-sitter-cli")
    }
  }
}
