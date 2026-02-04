//
//  LanguageChunker.swift
//  ASTChunker
//
//  Protocol for language-specific AST chunkers.
//

import Foundation

/// Protocol for language-specific AST chunkers
public protocol LanguageChunker: Sendable {
  /// Language identifier (e.g., "swift", "ruby")
  static var language: String { get }
  
  /// File extensions this chunker handles
  static var fileExtensions: Set<String> { get }
  
  /// Parse source and return semantic chunks
  /// - Parameters:
  ///   - source: The source code to parse
  ///   - maxChunkLines: Maximum lines per chunk (large constructs will be split)
  /// - Returns: Array of ASTChunk representing semantic boundaries
  func chunk(source: String, maxChunkLines: Int) -> [ASTChunk]
}

extension LanguageChunker {
  /// Check if this chunker handles the given file extension
  public static func handles(extension ext: String) -> Bool {
    fileExtensions.contains(ext.lowercased())
  }
  
  /// Check if this chunker handles the given filename
  public static func handles(filename: String) -> Bool {
    let ext = (filename as NSString).pathExtension.lowercased()
    return fileExtensions.contains(ext)
  }
}
