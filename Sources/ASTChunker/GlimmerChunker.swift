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
  
  public init(
    treeSitterLibPath: String = "~/code/tree-sitter-grammars/tree-sitter-glimmer-typescript/glimmer_typescript.dylib",
    treeSitterCLIPath: String = "/opt/homebrew/bin/tree-sitter"
  ) {
    self.treeSitterLibPath = (treeSitterLibPath as NSString).expandingTildeInPath
    self.treeSitterCLIPath = treeSitterCLIPath
    self.isAvailable = FileManager.default.fileExists(atPath: self.treeSitterLibPath) &&
                       FileManager.default.fileExists(atPath: treeSitterCLIPath)
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
        chunks.append(ASTChunk(
          constructType: construct.type,
          constructName: construct.name,
          startLine: construct.startLine + 1, // Convert to 1-indexed
          endLine: construct.endLine + 1,
          text: text,
          language: "Glimmer TypeScript"
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
        language: "Glimmer TypeScript"
      ))
    }
    
    return chunks
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
