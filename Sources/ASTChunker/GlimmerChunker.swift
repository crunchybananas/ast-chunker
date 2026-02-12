//
//  GlimmerChunker.swift
//  ASTChunker
//
//  GTS/GJS (Glimmer TypeScript/JavaScript) chunker using tree-sitter for parsing.
//

import Foundation

/// Glimmer TypeScript/JavaScript AST chunker using tree-sitter
public struct GlimmerChunker: LanguageChunker, Sendable {
  public static let language = "glimmer-typescript"
  public static let fileExtensions: Set<String> = ["gts", "gjs"]
  
  /// Path to tree-sitter dynamic library for Glimmer TypeScript
  private let treeSitterLibPath: String
  
  /// Path to tree-sitter CLI
  private let treeSitterCLIPath: String
  
  /// Whether the chunker is available (library and CLI exist)
  public let isAvailable: Bool

  /// Environment variable for Glimmer TypeScript library path
  public static let envLibPath = "AST_CHUNKER_GLIMMER_LIB"

  /// Environment variable for tree-sitter CLI path
  public static let envCLIPath = "AST_CHUNKER_TREE_SITTER_CLI"

  /// Common search paths for tree-sitter CLI
  private static let treeSitterCLISearchPaths = [
    "/opt/homebrew/bin/tree-sitter",
    "/usr/local/bin/tree-sitter",
    "/usr/bin/tree-sitter",
  ]
  
  public init(
    treeSitterLibPath: String? = nil,
    treeSitterCLIPath: String? = nil
  ) {
    let resolvedLibPath = treeSitterLibPath
      ?? ProcessInfo.processInfo.environment[Self.envLibPath]

    let resolvedCLIPath = treeSitterCLIPath
      ?? ProcessInfo.processInfo.environment[Self.envCLIPath]
      ?? Self.findTreeSitterCLI()

    self.treeSitterLibPath = resolvedLibPath.map { ($0 as NSString).expandingTildeInPath } ?? ""
    self.treeSitterCLIPath = resolvedCLIPath ?? ""
    self.isAvailable = !self.treeSitterLibPath.isEmpty &&
                       !self.treeSitterCLIPath.isEmpty &&
                       FileManager.default.fileExists(atPath: self.treeSitterLibPath) &&
                       FileManager.default.fileExists(atPath: self.treeSitterCLIPath)
  }

  /// Find tree-sitter CLI by searching common paths and PATH.
  /// Shared between GlimmerChunker and RubyChunker.
  public static func findTreeSitterCLI(searchPaths: [String]? = nil) -> String? {
    for path in (searchPaths ?? treeSitterCLISearchPaths) {
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
  
  public func chunk(source: String, maxChunkLines: Int = 200) -> [ASTChunk] {
    guard isAvailable else {
      return fallbackChunk(source: source)
    }
    
    // Write source to temp file
    let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("glimmer_\(UUID().uuidString).gts")
    
    do {
      try source.write(to: tempFile, atomically: true, encoding: .utf8)
      defer { try? FileManager.default.removeItem(at: tempFile) }
      
      // Parse with tree-sitter
      guard let ast = parseWithTreeSitter(file: tempFile.path) else {
        return fallbackChunk(source: source)
      }
      
      // Extract chunks from AST
      let chunks = extractChunks(from: ast, source: source, maxChunkLines: maxChunkLines)
      
      if chunks.isEmpty {
        return fallbackChunk(source: source)
      }
      
      return chunks
      
    } catch {
      return fallbackChunk(source: source)
    }
  }
  
  // MARK: - Tree-sitter Integration
  
  /// Timeout for tree-sitter parsing (in seconds)
  private let parseTimeout: TimeInterval = 5.0
  
  private func parseWithTreeSitter(file: String) -> String? {
    let process = Process()
    let pipe = Pipe()
    let errorPipe = Pipe()
    
    process.executableURL = URL(fileURLWithPath: treeSitterCLIPath)
    process.arguments = [
      "parse",
      "-l", treeSitterLibPath,
      "--lang-name", "glimmer_typescript",
      "--timeout", "3000000",  // 3 seconds in microseconds
      file
    ]
    process.standardOutput = pipe
    process.standardError = errorPipe
    
    // Set working directory to the grammar directory so it can find dependencies
    process.currentDirectoryURL = URL(fileURLWithPath: treeSitterLibPath).deletingLastPathComponent()
    
    // IMPORTANT: Read output asynchronously to prevent pipe buffer from filling up
    // and blocking the process. For large AST outputs (>64KB), the pipe buffer
    // fills and the process deadlocks waiting to write while we wait for it to exit.
    var outputData = Data()
    var errorData = Data()
    
    let outputHandle = pipe.fileHandleForReading
    let errorHandle = errorPipe.fileHandleForReading
    
    // Use DispatchGroup to coordinate async reads
    let group = DispatchGroup()
    
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      outputData = outputHandle.readDataToEndOfFile()
      group.leave()
    }
    
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      errorData = errorHandle.readDataToEndOfFile()
      group.leave()
    }
    
    do {
      try process.run()
      
      // Wait for process with timeout
      let result = group.wait(timeout: .now() + parseTimeout)
      
      if result == .timedOut {
        process.terminate()
        return nil
      }
      
      process.waitUntilExit()
      
      if process.terminationStatus != 0 {
        return nil
      }
      
      let ast = String(data: outputData, encoding: .utf8)
      return ast
    } catch {
      return nil
    }
  }
  
  // MARK: - AST Parsing
  
  private func extractChunks(from ast: String, source: String, maxChunkLines: Int) -> [ASTChunk] {
    let lines = source.components(separatedBy: "\n")
    var chunks: [ASTChunk] = []
    
    // Parse top-level constructs from tree-sitter output
    let constructs = parseTopLevelConstructs(from: ast, sourceLines: lines)
    
    for construct in constructs {
      if construct.endLine - construct.startLine + 1 <= maxChunkLines {
        // Construct fits in one chunk
        let text = extractLines(from: lines, start: construct.startLine, end: construct.endLine)
        let typeRefs = extractTypeReferences(from: text)
        chunks.append(ASTChunk(
          constructType: construct.type,
          constructName: construct.name,
          startLine: construct.startLine + 1, // Convert to 1-indexed
          endLine: construct.endLine + 1,
          text: text,
          language: "Glimmer TypeScript",
          metadata: ASTChunkMetadata(typeReferences: typeRefs)
        ))
      } else {
        // Split large construct into smaller chunks
        let subChunks = splitLargeConstruct(construct: construct, ast: ast, lines: lines, maxChunkLines: maxChunkLines)
        chunks.append(contentsOf: subChunks)
      }
    }
    
    return chunks
  }
  
  private struct ParsedConstruct {
    let type: ASTChunk.ConstructType
    let name: String?
    let startLine: Int  // 0-indexed
    let endLine: Int    // 0-indexed
    let rawType: String // Original AST type string
  }
  
  private func parseTopLevelConstructs(from ast: String, sourceLines: [String]) -> [ParsedConstruct] {
    var constructs: [ParsedConstruct] = []
    let astLines = ast.components(separatedBy: "\n")
    
    for line in astLines {
      // Top-level nodes have exactly 2 spaces of indentation
      // (program is at indent 0, its children are at indent 2)
      guard line.hasPrefix("  (") && !line.hasPrefix("    (") else { continue }
      
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      
      if let match = parseTopLevelNode(trimmed) {
        let name = extractNameFromAST(astLines: astLines, startLine: match.startLine, type: match.type, sourceLines: sourceLines)
        
        constructs.append(ParsedConstruct(
          type: mapConstructType(match.type),
          name: name,
          startLine: match.startLine,
          endLine: match.endLine,
          rawType: match.type
        ))
      }
    }
    
    return constructs
  }
  
  private func parseTopLevelNode(_ line: String) -> (type: String, startLine: Int, endLine: Int)? {
    // Match nodes at indentation level 2 (direct children of program)
    // Pattern: "  (node_type [start_row, start_col] - [end_row, end_col]"
    let pattern = #"^\((\w+) \[(\d+), \d+\] - \[(\d+), \d+\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
      return nil
    }
    
    guard let typeRange = Range(match.range(at: 1), in: line),
          let startRange = Range(match.range(at: 2), in: line),
          let endRange = Range(match.range(at: 3), in: line) else {
      return nil
    }
    
    let type = String(line[typeRange])
    
    // Filter for meaningful top-level constructs
    let meaningfulTypes: Set<String> = [
      "class_declaration",
      "interface_declaration",
      "type_alias_declaration",
      "function_declaration",
      "lexical_declaration",  // const/let at top level
      "export_statement",
      "import_statement",
      "comment"  // Include doc comments
    ]
    
    guard meaningfulTypes.contains(type) else { return nil }
    
    let startLine = Int(line[startRange]) ?? 0
    let endLine = Int(line[endRange]) ?? 0
    
    return (type, startLine, endLine)
  }
  
  private func extractNameFromAST(astLines: [String], startLine: Int, type: String, sourceLines: [String]) -> String? {
    // Look for identifier in the AST for this construct
    // Different types have different patterns
    switch type {
    case "class_declaration", "interface_declaration", "type_alias_declaration":
      // Look for "name: (type_identifier [startLine," in the AST
      for line in astLines {
        if line.contains("name:") && line.contains("[\(startLine),") {
          // Extract the identifier from the source
          if startLine < sourceLines.count {
            let sourceLine = sourceLines[startLine]
            // Match class/interface/type Name
            let patterns = [
              #"class\s+(\w+)"#,
              #"interface\s+(\w+)"#,
              #"type\s+(\w+)"#
            ]
            for pattern in patterns {
              if let regex = try? NSRegularExpression(pattern: pattern),
                 let match = regex.firstMatch(in: sourceLine, range: NSRange(sourceLine.startIndex..., in: sourceLine)),
                 let nameRange = Range(match.range(at: 1), in: sourceLine) {
                return String(sourceLine[nameRange])
              }
            }
          }
        }
      }
      
    case "function_declaration":
      if startLine < sourceLines.count {
        let sourceLine = sourceLines[startLine]
        if let regex = try? NSRegularExpression(pattern: #"function\s+(\w+)"#),
           let match = regex.firstMatch(in: sourceLine, range: NSRange(sourceLine.startIndex..., in: sourceLine)),
           let nameRange = Range(match.range(at: 1), in: sourceLine) {
          return String(sourceLine[nameRange])
        }
      }
      
    case "lexical_declaration":
      // const X = ... or let X = ...
      if startLine < sourceLines.count {
        let sourceLine = sourceLines[startLine]
        if let regex = try? NSRegularExpression(pattern: #"(?:const|let)\s+(\w+)"#),
           let match = regex.firstMatch(in: sourceLine, range: NSRange(sourceLine.startIndex..., in: sourceLine)),
           let nameRange = Range(match.range(at: 1), in: sourceLine) {
          return String(sourceLine[nameRange])
        }
      }
      
    default:
      break
    }
    
    return nil
  }
  
  private func mapConstructType(_ type: String) -> ASTChunk.ConstructType {
    switch type {
    case "class_declaration": return .classDecl
    case "interface_declaration": return .protocolDecl
    case "type_alias_declaration": return .protocolDecl
    case "function_declaration": return .function
    case "lexical_declaration": return .component  // const Component = <template>...
    case "export_statement": return .file
    case "import_statement": return .imports
    case "comment": return .file
    default: return .unknown
    }
  }
  
  private func splitLargeConstruct(construct: ParsedConstruct, ast: String, lines: [String], maxChunkLines: Int) -> [ASTChunk] {
    // For large constructs, split into roughly equal chunks with context
    var chunks: [ASTChunk] = []
    let totalLines = construct.endLine - construct.startLine + 1
    let numChunks = (totalLines + maxChunkLines - 1) / maxChunkLines
    let linesPerChunk = totalLines / numChunks
    
    for i in 0..<numChunks {
      let chunkStart = construct.startLine + (i * linesPerChunk)
      let chunkEnd = min(construct.startLine + ((i + 1) * linesPerChunk) - 1, construct.endLine)
      
      let text = extractLines(from: lines, start: chunkStart, end: chunkEnd)
      let name = construct.name.map { "\($0) (part \(i + 1)/\(numChunks))" }
      
      chunks.append(ASTChunk(
        constructType: construct.type,
        constructName: name,
        startLine: chunkStart + 1,
        endLine: chunkEnd + 1,
        text: text,
        language: "Glimmer TypeScript",
        metadata: ASTChunkMetadata(typeReferences: extractTypeReferences(from: text))
      ))
    }
    
    return chunks
  }
  
  // MARK: - Type Reference Extraction
  
  /// Extract type names referenced in Glimmer TypeScript/JavaScript source (for orphan detection).
  /// Handles the same TS/JS patterns plus Glimmer-specific template invocations.
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
      "ReturnType", "InstanceType", "Parameters", "ConstructorParameters"
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
      // Glimmer component invocations: <SomeComponent or <SomeComponent>
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
  
  private func extractLines(from lines: [String], start: Int, end: Int) -> String {
    guard start >= 0 && end < lines.count && start <= end else {
      return ""
    }
    return lines[start...end].joined(separator: "\n")
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
