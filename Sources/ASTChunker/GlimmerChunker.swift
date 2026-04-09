//
//  GlimmerChunker.swift
//  ASTChunker
//
//  GTS/GJS (Glimmer TypeScript/JavaScript) chunker using tree-sitter for parsing.
//  Uses native in-process tree-sitter (no CLI subprocess) for sandbox compatibility.
//

import Foundation

/// Glimmer TypeScript/JavaScript AST chunker using tree-sitter.
///
/// Primary path uses `NativeGlimmerParser` which links the tree-sitter C library
/// and Glimmer grammar directly — no subprocess, no dylib, works in App Store sandbox.
public struct GlimmerChunker: LanguageChunker, Sendable {
  public static let language = "glimmer-typescript"
  public static let fileExtensions: Set<String> = ["gts", "gjs"]

  /// The native parser is always available since it's compiled in.
  public let isAvailable: Bool = true

  private let nativeParser = NativeGlimmerParser()

  public init() {}

  public func chunk(source: String, maxChunkLines: Int = 200) -> [ASTChunk] {
    let chunks = nativeParser.parse(source: source, maxChunkLines: maxChunkLines)

    if chunks.isEmpty {
      return fallbackChunk(source: source)
    }

    return chunks
  }

  /// Find tree-sitter CLI by searching common paths and PATH.
  /// Shared utility used by other chunkers (RubyChunker, SwiftTreeSitterChunker).
  public static func findTreeSitterCLI(searchPaths: [String]? = nil) -> String? {
    let defaultPaths = [
      "/opt/homebrew/bin/tree-sitter",
      "/usr/local/bin/tree-sitter",
      "/usr/bin/tree-sitter",
    ]

    for path in (searchPaths ?? defaultPaths) {
      if FileManager.default.fileExists(atPath: path) {
        return path
      }
    }

    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = ["tree-sitter"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
      process.waitUntilExit()
      if process.terminationStatus == 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
          return path
        }
      }
    } catch {}

    return nil
  }

  private func fallbackChunk(source: String) -> [ASTChunk] {
    let lines = source.components(separatedBy: "\n")
    let chunkSize = 50
    var chunks: [ASTChunk] = []

    for i in stride(from: 0, to: lines.count, by: chunkSize) {
      let endIndex = min(i + chunkSize - 1, lines.count - 1)
      let text = lines[i...endIndex].joined(separator: "\n")

      chunks.append(ASTChunk(
        constructType: .file,
        constructName: nil,
        startLine: i + 1,
        endLine: endIndex + 1,
        text: text,
        language: "Glimmer TypeScript"
      ))
    }

    return chunks
  }
}
