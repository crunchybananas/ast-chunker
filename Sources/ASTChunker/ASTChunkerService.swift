//
//  ASTChunkerService.swift
//  ASTChunker
//
//  Main entry point for AST-based chunking across multiple languages.
//

import Foundation

/// Service that provides AST-aware chunking for multiple languages
public struct ASTChunkerService: Sendable {

  /// Default maximum lines per chunk
  public static let defaultMaxChunkLines = 150

  private let swiftChunker = SwiftChunker()
  private let swiftTreeSitterChunker: SwiftTreeSitterChunker?
  private let rubyChunker: RubyChunker?
  private let glimmerChunker: GlimmerChunker?
  private let jsCoreTypeScriptChunker: JSCoreTypeScriptChunker?

  public init(
    treeSitterLibPath: String? = nil,
    treeSitterCLIPath: String? = nil,
    glimmerLibPath: String? = nil,
    typescriptLibPath: String? = nil,
    swiftTreeSitterLibPath: String? = nil
  ) {
    // Initialize Ruby chunker if tree-sitter is available
    let cliPath = treeSitterCLIPath ?? "/opt/homebrew/bin/tree-sitter"
    let libPath = treeSitterLibPath ?? (("~/code/tree-sitter-grammars/tree-sitter-ruby/ruby.dylib" as NSString).expandingTildeInPath)

    if FileManager.default.fileExists(atPath: cliPath) &&
       FileManager.default.fileExists(atPath: libPath) {
      self.rubyChunker = RubyChunker(treeSitterLibPath: libPath, treeSitterCLIPath: cliPath)
    } else {
      self.rubyChunker = nil
    }

    // Initialize Glimmer (GTS/GJS) chunker
    let glimmerChunker = GlimmerChunker()
    self.glimmerChunker = glimmerChunker.isAvailable ? glimmerChunker : nil

    // Initialize Swift tree-sitter chunker if dylib is available
    let candidate = SwiftTreeSitterChunker(
      treeSitterLibPath: swiftTreeSitterLibPath,
      treeSitterCLIPath: treeSitterCLIPath
    )
    self.swiftTreeSitterChunker = candidate.isAvailable ? candidate : nil

    // Use the JavaScriptCore parser for TypeScript-family files. If a custom bundle path
    // is provided, construct a dedicated instance; otherwise use the shared singleton.
    let jsCoreTypeScriptChunker: JSCoreTypeScriptChunker = if let typescriptLibPath {
      JSCoreTypeScriptChunker(bundlePath: typescriptLibPath)
    } else {
      JSCoreTypeScriptChunker.shared
    }
    self.jsCoreTypeScriptChunker = jsCoreTypeScriptChunker.isAvailable ? jsCoreTypeScriptChunker : nil
  }

  /// Chunk source code with automatic language detection
  /// - Parameters:
  ///   - source: The source code to chunk
  ///   - filename: Filename to detect language from extension
  ///   - maxChunkLines: Maximum lines per chunk
  /// - Returns: Array of semantic chunks
  public func chunk(
    source: String,
    filename: String,
    maxChunkLines: Int = defaultMaxChunkLines
  ) -> [ASTChunk] {
    let language = detectLanguage(for: filename)

    switch language {
    case "swift":
      if let swiftTreeSitterChunker {
        return swiftTreeSitterChunker.chunk(source: source, maxChunkLines: maxChunkLines)
      }
      return swiftChunker.chunk(source: source, maxChunkLines: maxChunkLines)
    case "ruby":
      if let rubyChunker = rubyChunker {
        return rubyChunker.chunk(source: source, maxChunkLines: maxChunkLines)
      }
      return fallbackChunk(source: source, language: language, maxChunkLines: maxChunkLines)
    case "gts", "gjs":
      if let glimmerChunker = glimmerChunker {
        return glimmerChunker.chunk(source: source, maxChunkLines: maxChunkLines)
      }
      if let jsCoreTypeScriptChunker {
        return jsCoreTypeScriptChunker.chunk(source: source, language: language, maxChunkLines: maxChunkLines)
      }
      return fallbackChunk(source: source, language: language, maxChunkLines: maxChunkLines)
    case "typescript":
      if let jsCoreTypeScriptChunker {
        return jsCoreTypeScriptChunker.chunk(source: source, language: language, maxChunkLines: maxChunkLines)
      }
      return fallbackChunk(source: source, language: language, maxChunkLines: maxChunkLines)
    default:
      return fallbackChunk(source: source, language: language, maxChunkLines: maxChunkLines)
    }
  }

  /// Detect language from filename
  public func detectLanguage(for filename: String) -> String {
    let lowercased = filename.lowercased()
    let ext = (lowercased as NSString).pathExtension

    // Swift
    if ext == "swift" {
      return "swift"
    }

    // Ruby (for future)
    if ext == "rb" || ext == "rake" || ext == "gemspec" ||
       lowercased.hasSuffix("gemfile") || lowercased.hasSuffix("rakefile") {
      return "ruby"
    }

    // GTS/GJS (Glimmer TypeScript/JavaScript)
    if ext == "gts" {
      return "gts"
    }
    if ext == "gjs" {
      return "gjs"
    }

    // TypeScript/JavaScript (regular, without Glimmer templates)
    if ["ts", "tsx", "js", "jsx", "mts", "cts", "mjs", "cjs"].contains(ext) {
      return "typescript"
    }

    // Python (future)
    if ext == "py" {
      return "python"
    }

    // Rust (future)
    if ext == "rs" {
      return "rust"
    }

    return "unknown"
  }

  /// Basic line-based chunking fallback
  private func fallbackChunk(
    source: String,
    language: String,
    maxChunkLines: Int
  ) -> [ASTChunk] {
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard !lines.isEmpty else { return [] }

    var chunks: [ASTChunk] = []
    var start = 0

    while start < lines.count {
      let end = min(start + maxChunkLines, lines.count)
      let chunkLines = lines[start..<end]

      chunks.append(ASTChunk(
        constructType: .file,
        constructName: nil,
        startLine: start + 1,
        endLine: end,
        text: chunkLines.joined(separator: "\n"),
        language: language
      ))

      start = end
    }

    return chunks
  }
}
