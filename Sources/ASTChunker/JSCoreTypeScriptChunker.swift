//
//  JSCoreTypeScriptChunker.swift
//  ASTChunker
//
//  TypeScript/JavaScript/GTS/GJS AST chunker using JavaScriptCore + @babel/parser
//

import Foundation
import JavaScriptCore

/// TypeScript/JavaScript/GTS/GJS AST chunker using JavaScriptCore
/// This uses @babel/parser bundled in ast-chunker.bundle.js for accurate parsing.
public final class JSCoreTypeScriptChunker: @unchecked Sendable {
  public static let language = "typescript"
  public static let fileExtensions: Set<String> = [
    "ts", "tsx", "js", "jsx", "mts", "cts", "mjs", "cjs",
    "gts", "gjs"  // Glimmer TypeScript/JavaScript
  ]
  
  /// The JavaScript context with the bundled parser
  private let context: JSContext
  
  /// Whether the chunker is available (bundle loaded successfully)
  public let isAvailable: Bool
  
  /// Error message if initialization failed
  public let initError: String?
  
  /// Shared instance (lazy initialization)
  public static let shared: JSCoreTypeScriptChunker = JSCoreTypeScriptChunker()
  
  public init(bundlePath: String? = nil) {
    // Create JS context
    guard let ctx = JSContext() else {
      self.context = JSContext()!  // Fallback, but mark unavailable
      self.isAvailable = false
      self.initError = "Failed to create JSContext"
      return
    }
    
    self.context = ctx
    
    // Set up exception handler
    ctx.exceptionHandler = { _, exception in
      if let exc = exception {
        print("[JSCoreTypeScriptChunker] JS Exception: \(exc)")
      }
    }
    
    // Find and load the bundle
    let bundleURL: URL?
    
    if let path = bundlePath {
      bundleURL = URL(fileURLWithPath: path)
    } else {
      bundleURL = Self.findBundle()
    }
    
    guard let url = bundleURL else {
      self.isAvailable = false
      self.initError = "Could not find ast-chunker.bundle.js"
      return
    }
    
    // Load the bundle
    do {
      let bundleSource = try String(contentsOf: url, encoding: .utf8)
      ctx.evaluateScript(bundleSource)
      
      // Verify the bundle loaded correctly by checking for parseAndChunk function
      let parseFunc = ctx.evaluateScript("typeof ASTChunker.parseAndChunk")
      if parseFunc?.toString() != "function" {
        self.isAvailable = false
        self.initError = "Bundle loaded but ASTChunker.parseAndChunk is not a function (got: \(parseFunc?.toString() ?? "nil"))"
        return
      }
      
      self.isAvailable = true
      self.initError = nil
      print("[JSCoreTypeScriptChunker] Loaded bundle from \(url.path)")
      
    } catch {
      self.isAvailable = false
      self.initError = "Failed to load bundle: \(error.localizedDescription)"
    }
  }
  
  /// Find the ast-chunker.bundle.js file
  private static func findBundle() -> URL? {
    // Check in app bundle Resources
    if let bundlePath = Bundle.main.path(forResource: "ast-chunker.bundle", ofType: "js") {
      return URL(fileURLWithPath: bundlePath)
    }
    
    // Check in app bundle Frameworks
    if let frameworksPath = Bundle.main.privateFrameworksPath {
      let bundlePath = (frameworksPath as NSString).appendingPathComponent("ast-chunker.bundle.js")
      if FileManager.default.fileExists(atPath: bundlePath) {
        return URL(fileURLWithPath: bundlePath)
      }
    }
    
    // Development: check Tools directory
    let devPaths = [
      "~/code/KitchenSink/Tools/ast-chunker-js/dist/ast-chunker.bundle.js",
    ]
    
    for path in devPaths {
      let expanded = (path as NSString).expandingTildeInPath
      if FileManager.default.fileExists(atPath: expanded) {
        return URL(fileURLWithPath: expanded)
      }
    }
    
    return nil
  }
  
  /// Chunk source code
  /// - Parameters:
  ///   - source: The source code to parse
  ///   - language: The language ('typescript', 'javascript', 'gts', 'gjs')
  ///   - maxChunkLines: Maximum lines per chunk (default 200)
  /// - Returns: Array of chunks, or fallback line-based chunks on error
  public func chunk(source: String, language: String = "typescript", maxChunkLines: Int = 200) -> [ASTChunk] {
    guard isAvailable else {
      print("[JSCoreTypeScriptChunker] Not available: \(initError ?? "unknown error")")
      return fallbackChunk(source: source)
    }
    
    // Map file extension to language
    let lang = mapLanguage(language)
    
    // Escape source for JavaScript string
    let escapedSource = escapeForJS(source)
    
    // Call the JS function
    let script = "ASTChunker.parseAndChunk(\(escapedSource), '\(lang)')"
    guard let result = context.evaluateScript(script) else {
      print("[JSCoreTypeScriptChunker] evaluateScript returned nil")
      return fallbackChunk(source: source)
    }
    
    guard let jsonString = result.toString(), !jsonString.isEmpty else {
      print("[JSCoreTypeScriptChunker] Result is not a string")
      return fallbackChunk(source: source)
    }
    
    // Parse JSON result
    guard let jsonData = jsonString.data(using: .utf8) else {
      print("[JSCoreTypeScriptChunker] Failed to convert JSON to data")
      return fallbackChunk(source: source)
    }
    
    do {
      // Check for error response
      if let errorResponse = try? JSONDecoder().decode(JSErrorResponse.self, from: jsonData),
         errorResponse.error {
        print("[JSCoreTypeScriptChunker] JS parse error: \(errorResponse.message)")
        return fallbackChunk(source: source)
      }
      
      // Parse chunks
      let jsChunks = try JSONDecoder().decode([JSChunk].self, from: jsonData)
      
      if jsChunks.isEmpty {
        return fallbackChunk(source: source)
      }
      
      // Convert to ASTChunk with metadata
      return jsChunks.map { js in
        let metadata = convertJSMetadata(js.metadata, language: language)
        return ASTChunk(
          constructType: mapConstructType(js.constructType),
          constructName: js.constructName,
          startLine: js.startLine,
          endLine: js.endLine,
          text: js.text,
          language: language,
          metadata: metadata
        )
      }
      
    } catch {
      print("[JSCoreTypeScriptChunker] JSON decode error: \(error)")
      return fallbackChunk(source: source)
    }
  }
  
  // MARK: - Private Helpers
  
  private struct JSChunk: Codable {
    let startLine: Int
    let endLine: Int
    let text: String
    let constructType: String
    let constructName: String?
    let tokenCount: Int
    let metadata: JSChunkMetadata?
  }
  
  private struct JSChunkMetadata: Codable {
    let decorators: [String]?
    let protocols: [String]?
    let imports: [String]?
    let superclass: String?
    let usesEmberConcurrency: Bool?
    let hasTemplate: Bool?
    let tioUiImports: [String]?
    let frameworks: [String]?
  }
  
  private struct JSErrorResponse: Codable {
    let error: Bool
    let message: String
  }
  
  /// Map file extension to language identifier
  private func mapLanguage(_ ext: String) -> String {
    switch ext.lowercased() {
    case "ts", "tsx", "mts", "cts":
      return "typescript"
    case "js", "jsx", "mjs", "cjs":
      return "javascript"
    case "gts":
      return "gts"
    case "gjs":
      return "gjs"
    default:
      return "typescript"  // Default to TS
    }
  }
  
  /// Map JS construct type to ASTChunk.ConstructType
  private func mapConstructType(_ jsType: String) -> ASTChunk.ConstructType {
    switch jsType {
    case "classDecl":
      return .classDecl
    case "function":
      return .function
    case "protocolDecl":
      return .protocolDecl
    case "enumDecl":
      return .enumDecl
    case "imports":
      return .imports
    default:
      return .unknown
    }
  }
  
  /// Convert JS metadata to ASTChunkMetadata
  private func convertJSMetadata(_ jsMetadata: JSChunkMetadata?, language: String) -> ASTChunkMetadata {
    guard let js = jsMetadata else {
      return ASTChunkMetadata()
    }
    
    return ASTChunkMetadata(
      decorators: js.decorators ?? [],
      protocols: js.protocols ?? [],
      imports: js.imports ?? [],
      superclass: js.superclass,
      usesEmberConcurrency: js.usesEmberConcurrency ?? false,
      hasTemplate: js.hasTemplate ?? false,
      tioUiImports: js.tioUiImports ?? [],
      frameworks: js.frameworks ?? []
    )
  }
  
  /// Escape source code for JavaScript string literal
  private func escapeForJS(_ source: String) -> String {
    // Use JSON encoding which handles all escaping properly
    if let data = try? JSONEncoder().encode(source),
       let json = String(data: data, encoding: .utf8) {
      return json
    }
    // Fallback: basic escaping - build the string step by step
    var escaped = source
    escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
    escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
    escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
    escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
    escaped = escaped.replacingOccurrences(of: "\t", with: "\\t")
    return "\"\(escaped)\""
  }
  
  /// Fallback to line-based chunking
  private func fallbackChunk(source: String) -> [ASTChunk] {
    let lines = source.components(separatedBy: "\n")
    let maxLines = 100
    var chunks: [ASTChunk] = []
    var currentStart = 1
    
    while currentStart <= lines.count {
      let currentEnd = min(currentStart + maxLines - 1, lines.count)
      let chunkLines = lines[(currentStart - 1)..<currentEnd]
      let text = chunkLines.joined(separator: "\n")
      
      chunks.append(ASTChunk(
        constructType: .file,
        constructName: nil,
        startLine: currentStart,
        endLine: currentEnd,
        text: text,
        language: Self.language
      ))
      
      currentStart = currentEnd + 1
    }
    
    return chunks
  }
}
