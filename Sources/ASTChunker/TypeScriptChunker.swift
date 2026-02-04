//
//  TypeScriptChunker.swift
//  ASTChunker
//
//  TypeScript/JavaScript AST chunker using tree-sitter for parsing.
//

import Foundation

/// TypeScript/JavaScript AST chunker using tree-sitter
public struct TypeScriptChunker: LanguageChunker, Sendable {
  public static let language = "typescript"
  public static let fileExtensions: Set<String> = ["ts", "tsx", "js", "jsx", "mts", "cts", "mjs", "cjs"]
  
  /// Path to tree-sitter dynamic library for TypeScript
  private let treeSitterLibPath: String
  
  /// Path to tree-sitter CLI
  private let treeSitterCLIPath: String
  
  /// Whether the chunker is available (library and CLI exist)
  public let isAvailable: Bool
  
  public init(
    treeSitterLibPath: String = "~/code/tree-sitter-grammars/tree-sitter-typescript/typescript.dylib",
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
    let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("ts_\(UUID().uuidString).ts")
    
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
    
    process.executableURL = URL(fileURLWithPath: treeSitterCLIPath)
    process.arguments = [
      "parse",
      "-l", treeSitterLibPath,
      "--lang-name", "typescript",
      "--timeout", "3000000",  // 3 seconds in microseconds
      file
    ]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    
    do {
      try process.run()
      
      // Wait with timeout to prevent hanging (same pattern as RubyChunker)
      let deadline = Date().addingTimeInterval(parseTimeout)
      while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
      }
      
      if process.isRunning {
        // Process timed out - kill it
        process.terminate()
        return nil
      }
      
      guard process.terminationStatus == 0 else { return nil }
      
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      return String(data: data, encoding: .utf8)
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
        let text = extractLines(from: lines, start: construct.startLine, end: construct.endLine)
        chunks.append(ASTChunk(
          constructType: construct.type,
          constructName: construct.name,
          startLine: construct.startLine + 1, // Convert to 1-indexed
          endLine: construct.endLine + 1,
          text: text,
          language: "TypeScript"
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
    let rawType: String
  }
  
  private func parseTopLevelConstructs(from ast: String, sourceLines: [String]) -> [ParsedConstruct] {
    var constructs: [ParsedConstruct] = []
    let astLines = ast.components(separatedBy: "\n")
    
    for (index, line) in astLines.enumerated() {
      // Top-level nodes have exactly 2 spaces of indentation
      guard line.hasPrefix("  (") && !line.hasPrefix("    (") else { continue }
      
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      
      if let match = parseTopLevelNode(trimmed) {
        let name = extractNameFromAST(astLines: astLines, startLine: match.startLine, type: match.type, sourceLines: sourceLines)
        
        // For export_statement, look at the nested declaration to determine the real type
        var constructType = mapConstructType(match.type)
        if match.type == "export_statement" {
          constructType = determineExportedConstructType(astLines: astLines, startIndex: index, sourceLines: sourceLines, at: match.startLine)
        }
        
        constructs.append(ParsedConstruct(
          type: constructType,
          name: name,
          startLine: match.startLine,
          endLine: match.endLine,
          rawType: match.type
        ))
      }
    }
    
    return constructs
  }
  
  /// Determines the actual construct type from an export_statement by looking at the nested declaration
  private func determineExportedConstructType(astLines: [String], startIndex: Int, sourceLines: [String], at lineIndex: Int) -> ASTChunk.ConstructType {
    // First, look in the AST for a "declaration:" child node
    for i in (startIndex + 1)..<astLines.count {
      let line = astLines[i]
      // Stop if we hit another top-level node
      if line.hasPrefix("  (") && !line.hasPrefix("    ") {
        break
      }
      
      // Look for declaration: (some_declaration pattern
      if line.contains("declaration:") {
        if line.contains("class_declaration") || line.contains("abstract_class_declaration") {
          return .classDecl
        } else if line.contains("interface_declaration") {
          return .protocolDecl
        } else if line.contains("type_alias_declaration") {
          return .protocolDecl
        } else if line.contains("enum_declaration") {
          return .enumDecl
        } else if line.contains("function_declaration") || line.contains("generator_function_declaration") {
          return .function
        } else if line.contains("lexical_declaration") || line.contains("variable_declaration") {
          return .property
        }
      }
    }
    
    // Fallback: parse the source line directly
    guard lineIndex < sourceLines.count else { return .unknown }
    let sourceLine = sourceLines[lineIndex]
    
    if sourceLine.contains("export class ") || sourceLine.contains("export abstract class ") {
      return .classDecl
    } else if sourceLine.contains("export interface ") {
      return .protocolDecl
    } else if sourceLine.contains("export type ") {
      return .protocolDecl
    } else if sourceLine.contains("export enum ") {
      return .enumDecl
    } else if sourceLine.contains("export function ") || sourceLine.contains("export async function ") {
      return .function
    } else if sourceLine.contains("export const ") || sourceLine.contains("export let ") || sourceLine.contains("export var ") {
      return .property
    } else if sourceLine.contains("export default ") {
      // For default exports, try to determine what's being exported
      if sourceLine.contains("class ") {
        return .classDecl
      } else if sourceLine.contains("function ") {
        return .function
      }
      return .unknown
    }
    
    return .unknown
  }
  
  private func parseTopLevelNode(_ line: String) -> (type: String, startLine: Int, endLine: Int)? {
    // Pattern: "(node_type [start_row, start_col] - [end_row, end_col]"
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
      "abstract_class_declaration",
      "interface_declaration",
      "type_alias_declaration",
      "enum_declaration",
      "function_declaration",
      "generator_function_declaration",
      "lexical_declaration",   // const/let at top level (includes exported consts)
      "variable_declaration",  // var at top level
      "export_statement",
      "import_statement",
      "ambient_declaration",   // declare statements
      "module",                // namespace/module declarations
      "comment"
    ]
    
    guard meaningfulTypes.contains(type) else { return nil }
    
    let startLine = Int(line[startRange]) ?? 0
    let endLine = Int(line[endRange]) ?? 0
    
    return (type, startLine, endLine)
  }
  
  private func extractNameFromAST(astLines: [String], startLine: Int, type: String, sourceLines: [String]) -> String? {
    switch type {
    case "class_declaration", "abstract_class_declaration":
      return extractClassName(from: sourceLines, at: startLine)
    case "interface_declaration":
      return extractInterfaceName(from: sourceLines, at: startLine)
    case "type_alias_declaration":
      return extractTypeName(from: sourceLines, at: startLine)
    case "enum_declaration":
      return extractEnumName(from: sourceLines, at: startLine)
    case "function_declaration", "generator_function_declaration":
      return extractFunctionName(from: sourceLines, at: startLine)
    case "export_statement":
      // Look for the actual exported construct name
      return extractExportedName(from: sourceLines, at: startLine, astLines: astLines)
    case "lexical_declaration", "variable_declaration":
      return extractVariableName(from: sourceLines, at: startLine)
    default:
      return nil
    }
  }
  
  private func extractClassName(from lines: [String], at lineIndex: Int) -> String? {
    guard lineIndex < lines.count else { return nil }
    let line = lines[lineIndex]
    // Pattern: class ClassName or export class ClassName or abstract class ClassName
    let pattern = #"(?:export\s+)?(?:abstract\s+)?class\s+(\w+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let nameRange = Range(match.range(at: 1), in: line) else {
      return nil
    }
    return String(line[nameRange])
  }
  
  private func extractInterfaceName(from lines: [String], at lineIndex: Int) -> String? {
    guard lineIndex < lines.count else { return nil }
    let line = lines[lineIndex]
    // Pattern: interface InterfaceName or export interface InterfaceName
    let pattern = #"(?:export\s+)?interface\s+(\w+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let nameRange = Range(match.range(at: 1), in: line) else {
      return nil
    }
    return String(line[nameRange])
  }
  
  private func extractTypeName(from lines: [String], at lineIndex: Int) -> String? {
    guard lineIndex < lines.count else { return nil }
    let line = lines[lineIndex]
    // Pattern: type TypeName or export type TypeName
    let pattern = #"(?:export\s+)?type\s+(\w+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let nameRange = Range(match.range(at: 1), in: line) else {
      return nil
    }
    return String(line[nameRange])
  }
  
  private func extractEnumName(from lines: [String], at lineIndex: Int) -> String? {
    guard lineIndex < lines.count else { return nil }
    let line = lines[lineIndex]
    // Pattern: enum EnumName or export enum EnumName or const enum EnumName
    let pattern = #"(?:export\s+)?(?:const\s+)?enum\s+(\w+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let nameRange = Range(match.range(at: 1), in: line) else {
      return nil
    }
    return String(line[nameRange])
  }
  
  private func extractFunctionName(from lines: [String], at lineIndex: Int) -> String? {
    guard lineIndex < lines.count else { return nil }
    let line = lines[lineIndex]
    // Pattern: function functionName or export function functionName or async function functionName
    let pattern = #"(?:export\s+)?(?:async\s+)?function\s*\*?\s*(\w+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let nameRange = Range(match.range(at: 1), in: line) else {
      return nil
    }
    return String(line[nameRange])
  }
  
  private func extractVariableName(from lines: [String], at lineIndex: Int) -> String? {
    guard lineIndex < lines.count else { return nil }
    let line = lines[lineIndex]
    // Pattern: const/let/var variableName or export const/let/var variableName
    let pattern = #"(?:export\s+)?(?:const|let|var)\s+(\w+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let nameRange = Range(match.range(at: 1), in: line) else {
      return nil
    }
    return String(line[nameRange])
  }
  
  private func extractExportedName(from lines: [String], at lineIndex: Int, astLines: [String]) -> String? {
    guard lineIndex < lines.count else { return nil }
    let line = lines[lineIndex]
    
    // Try to extract class, interface, type, function, or variable name from export statement
    if let name = extractClassName(from: lines, at: lineIndex) { return name }
    if let name = extractInterfaceName(from: lines, at: lineIndex) { return name }
    if let name = extractTypeName(from: lines, at: lineIndex) { return name }
    if let name = extractEnumName(from: lines, at: lineIndex) { return name }
    if let name = extractFunctionName(from: lines, at: lineIndex) { return name }
    if let name = extractVariableName(from: lines, at: lineIndex) { return name }
    
    // Check for export default
    if line.contains("export default") {
      let pattern = #"export\s+default\s+(?:class|function|interface)?\s*(\w+)?"#
      if let regex = try? NSRegularExpression(pattern: pattern),
         let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
         match.range(at: 1).location != NSNotFound,
         let nameRange = Range(match.range(at: 1), in: line) {
        return String(line[nameRange])
      }
      return "default"
    }
    
    return nil
  }
  
  private func mapConstructType(_ rawType: String) -> ASTChunk.ConstructType {
    switch rawType {
    case "class_declaration", "abstract_class_declaration":
      return .classDecl
    case "interface_declaration":
      return .protocolDecl  // Using protocolDecl for interfaces
    case "type_alias_declaration":
      return .protocolDecl  // Type aliases are similar to protocols
    case "enum_declaration":
      return .enumDecl
    case "function_declaration", "generator_function_declaration":
      return .function
    case "import_statement":
      return .imports
    case "export_statement":
      // Will be refined based on what's being exported
      return .unknown
    case "lexical_declaration", "variable_declaration":
      return .property
    case "module":
      return .module
    default:
      return .unknown
    }
  }
  
  // MARK: - Large Construct Splitting
  
  private func splitLargeConstruct(
    construct: ParsedConstruct,
    ast: String,
    lines: [String],
    maxChunkLines: Int
  ) -> [ASTChunk] {
    // For now, do simple line-based splitting with overlap
    var chunks: [ASTChunk] = []
    var currentStart = construct.startLine
    let overlapLines = 5
    
    while currentStart <= construct.endLine {
      let currentEnd = min(currentStart + maxChunkLines - 1, construct.endLine)
      let text = extractLines(from: lines, start: currentStart, end: currentEnd)
      
      // For sub-chunks, use the parent name with a suffix
      let subName: String?
      if let parentName = construct.name {
        if chunks.isEmpty {
          subName = parentName
        } else {
          subName = "\(parentName)#part\(chunks.count + 1)"
        }
      } else {
        subName = nil
      }
      
      chunks.append(ASTChunk(
        constructType: construct.type,
        constructName: subName,
        startLine: currentStart + 1,  // Convert to 1-indexed
        endLine: currentEnd + 1,
        text: text,
        language: "TypeScript"
      ))
      
      currentStart = currentEnd + 1 - overlapLines
      if currentStart <= construct.startLine {
        currentStart = currentEnd + 1
      }
    }
    
    return chunks
  }
  
  private func extractLines(from lines: [String], start: Int, end: Int) -> String {
    let safeStart = max(0, start)
    let safeEnd = min(lines.count - 1, end)
    guard safeStart <= safeEnd else { return "" }
    return lines[safeStart...safeEnd].joined(separator: "\n")
  }
  
  // MARK: - Fallback
  
  private func fallbackChunk(source: String) -> [ASTChunk] {
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard !lines.isEmpty else { return [] }
    
    let maxLines = 150
    var chunks: [ASTChunk] = []
    var start = 0
    
    while start < lines.count {
      let end = min(start + maxLines, lines.count)
      let chunkLines = lines[start..<end]
      
      chunks.append(ASTChunk(
        constructType: .file,
        constructName: nil,
        startLine: start + 1,
        endLine: end,
        text: chunkLines.joined(separator: "\n"),
        language: "TypeScript"
      ))
      
      start = end
    }
    
    return chunks
  }
}
