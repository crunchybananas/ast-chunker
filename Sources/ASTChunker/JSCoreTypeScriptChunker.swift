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
    
    // Development: resolve relative to this source file's location
    // #filePath gives the compile-time path of this .swift file,
    // so we walk up to the repo root regardless of folder name.
    let repoRoot = Self.findRepoRoot()
    if let root = repoRoot {
      let bundlePath = (root as NSString).appendingPathComponent("Tools/ast-chunker-js/dist/ast-chunker.bundle.js")
      if FileManager.default.fileExists(atPath: bundlePath) {
        return URL(fileURLWithPath: bundlePath)
      }
    }
    
    return nil
  }
  
  /// Find the repo root from #filePath (compile-time source location)
  /// This file lives at: <repo>/Local Packages/ASTChunker/Sources/ASTChunker/JSCoreTypeScriptChunker.swift
  /// So we walk up 5 directory levels to get the repo root.
  private static func findRepoRoot() -> String? {
    var url = URL(fileURLWithPath: #filePath)
    // Walk up: ASTChunker/ -> Sources/ -> ASTChunker/ -> Local Packages/ -> <repo root>
    for _ in 0..<5 {
      url = url.deletingLastPathComponent()
    }
    let root = url.path
    // Verify it looks like the repo root (has Tools/ directory)
    if FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("Tools")) {
      return root
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
        let metadata = convertJSMetadata(js.metadata, language: language, chunkText: js.text)
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
  private func convertJSMetadata(_ jsMetadata: JSChunkMetadata?, language: String, chunkText: String) -> ASTChunkMetadata {
    guard let js = jsMetadata else {
      return ASTChunkMetadata(typeReferences: extractTypeReferences(from: chunkText))
    }
    
    return ASTChunkMetadata(
      decorators: js.decorators ?? [],
      protocols: js.protocols ?? [],
      imports: js.imports ?? [],
      superclass: js.superclass,
      usesEmberConcurrency: js.usesEmberConcurrency ?? false,
      hasTemplate: js.hasTemplate ?? false,
      tioUiImports: js.tioUiImports ?? [],
      frameworks: js.frameworks ?? [],
      typeReferences: extractTypeReferences(from: chunkText)
    )
  }
  
  // MARK: - Type Reference Extraction
  
  /// Extract type names referenced in TypeScript/JavaScript source text (for orphan detection).
  /// Uses regex patterns to find type annotations, instantiations, extends/implements, and imports.
  private func extractTypeReferences(from text: String) -> [String] {
    var refs = Set<String>()
    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)
    
    let builtins: Set<String> = [
      "string", "number", "boolean", "void", "any", "unknown", "never", "null",
      "undefined", "object", "symbol", "bigint",
      "String", "Number", "Boolean", "Object", "Symbol", "BigInt",
      "Array", "Map", "Set", "WeakMap", "WeakSet", "Promise", "Date",
      "Error", "RegExp", "Function", "Record", "Partial", "Required",
      "Readonly", "Pick", "Omit", "Exclude", "Extract", "NonNullable",
      "ReturnType", "InstanceType", "Parameters", "ConstructorParameters",
      "Awaited", "Uppercase", "Lowercase", "Capitalize", "Uncapitalize"
    ]
    
    let patterns: [(String, Int)] = [
      (#":\s+([A-Z]\w+)"#, 1),
      (#"\bas\s+([A-Z]\w+)"#, 1),
      (#"\bnew\s+([A-Z]\w+)"#, 1),
      (#"\b(?:extends|implements)\s+([A-Z]\w+)"#, 1),
      (#"<([A-Z]\w+)[,>]"#, 1),
      (#"import\s+\{([^}]+)\}\s+from"#, 1),
      (#"\btypeof\s+([A-Z]\w+)"#, 1),
      (#"\b([A-Z]\w+)\.\w+"#, 1),
      // Glimmer/JSX component invocations: <SomeComponent
      (#"<([A-Z]\w+)[\s/>]"#, 1),
    ]
    
    for (pattern, group) in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let matches = regex.matches(in: text, range: fullRange)
      
      for match in matches {
        guard match.numberOfRanges > group else { continue }
        let range = match.range(at: group)
        guard range.location != NSNotFound else { continue }
        let captured = nsText.substring(with: range)
        
        if pattern.contains("import") {
          let names = captured.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.components(separatedBy: " as ").first ?? $0 }
            .filter { !$0.isEmpty && $0.first?.isUppercase == true }
          for name in names {
            let cleaned = name.trimmingCharacters(in: .whitespaces)
            if !builtins.contains(cleaned) {
              refs.insert(cleaned)
            }
          }
        } else if !builtins.contains(captured) {
          refs.insert(captured)
        }
      }
    }
    
    return refs.sorted()
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
  
  /// Fallback to line-based chunking with basic import extraction
  private func fallbackChunk(source: String) -> [ASTChunk] {
    let lines = source.components(separatedBy: "\n")
    let maxLines = 100
    var chunks: [ASTChunk] = []
    var currentStart = 1
    
    // Extract imports via regex so dependencies aren't lost on fallback
    let fallbackMetadata = extractFallbackMetadata(from: source)
    
    while currentStart <= lines.count {
      let currentEnd = min(currentStart + maxLines - 1, lines.count)
      let chunkLines = lines[(currentStart - 1)..<currentEnd]
      let text = chunkLines.joined(separator: "\n")
      
      // Attach import metadata to the first chunk, type refs to all chunks
      var metadata = currentStart == 1 ? fallbackMetadata : ASTChunkMetadata()
      metadata.typeReferences = extractTypeReferences(from: text)
      
      chunks.append(ASTChunk(
        constructType: .file,
        constructName: nil,
        startLine: currentStart,
        endLine: currentEnd,
        text: text,
        language: Self.language,
        metadata: metadata
      ))
      
      currentStart = currentEnd + 1
    }
    
    return chunks
  }
  
  /// Extract basic metadata from source using regex (used when AST parsing fails)
  private func extractFallbackMetadata(from source: String) -> ASTChunkMetadata {
    var imports: [String] = []
    var frameworks: [String] = []
    var hasTemplate = false
    var usesEmberConcurrency = false
    var tioUiImports: [String] = []
    
    // Match ES import statements: import ... from 'module-path'
    let importRegex = try? NSRegularExpression(
      pattern: #"import\s+(?:(?:\{[^}]*\}|[^;{]*)\s+from\s+)?['"]([^'"]+)['"]"#,
      options: []
    )
    let nsSource = source as NSString
    let matches = importRegex?.matches(in: source, range: NSRange(location: 0, length: nsSource.length)) ?? []
    
    for match in matches {
      if match.numberOfRanges > 1 {
        let importPath = nsSource.substring(with: match.range(at: 1))
        imports.append(importPath)
        
        if importPath == "ember-concurrency" {
          usesEmberConcurrency = true
        }
        if importPath.hasPrefix("@glimmer/") || importPath.hasPrefix("@ember/") {
          if !frameworks.contains("Ember") { frameworks.append("Ember") }
        }
        if importPath.hasPrefix("tio-ui/") {
          tioUiImports.append(importPath)
        }
      }
    }
    
    // Detect <template> tag
    if source.contains("<template>") || source.contains("<template ") {
      hasTemplate = true
      if !frameworks.contains("Ember") { frameworks.append("Ember") }
    }
    
    return ASTChunkMetadata(
      imports: imports,
      usesEmberConcurrency: usesEmberConcurrency,
      hasTemplate: hasTemplate,
      tioUiImports: tioUiImports,
      frameworks: frameworks,
      typeReferences: extractTypeReferences(from: source)
    )
  }
}
