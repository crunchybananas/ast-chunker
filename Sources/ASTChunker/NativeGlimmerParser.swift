//
//  NativeGlimmerParser.swift
//  ASTChunker
//
//  Native tree-sitter parser for Glimmer TypeScript/JavaScript.
//  Replaces the CLI subprocess approach for sandbox compatibility.
//

import CTreeSitter
import CTreeSitterGlimmer
import Foundation

/// Parsed node from tree-sitter AST
struct TSNodeInfo {
  let type: String
  let startRow: Int   // 0-indexed
  let endRow: Int     // 0-indexed
  let childCount: Int
  let isNamed: Bool
}

/// Native tree-sitter parser for GTS/GJS files.
/// Runs entirely in-process — no subprocess, no dylib, no sandbox issues.
public struct NativeGlimmerParser: Sendable {
  public init() {}

  /// Parse source and extract top-level AST constructs.
  /// Returns chunks with proper construct types (classDecl, component, function, imports, etc.)
  public func parse(source: String, maxChunkLines: Int = 200) -> [ASTChunk] {
    guard let tree = parseSource(source) else {
      return []
    }
    defer { ts_tree_delete(tree) }

    let rootNode = ts_tree_root_node(tree)
    let lines = source.components(separatedBy: "\n")

    let constructs = extractTopLevelConstructs(rootNode, sourceLines: lines)

    var chunks: [ASTChunk] = []
    for construct in constructs {
      let lineCount = construct.endLine - construct.startLine + 1

      if lineCount <= maxChunkLines {
        let text = extractLines(from: lines, start: construct.startLine, end: construct.endLine)
        let typeRefs = extractTypeReferences(from: text)
        chunks.append(ASTChunk(
          constructType: construct.type,
          constructName: construct.name,
          startLine: construct.startLine + 1, // Convert to 1-indexed
          endLine: construct.endLine + 1,
          text: text,
          language: "Glimmer TypeScript",
          metadata: ASTChunkMetadata(
            protocols: construct.protocols,
            superclass: construct.superclass,
            typeReferences: typeRefs
          )
        ))
      } else {
        // Split large construct
        let subChunks = splitLargeConstruct(construct, lines: lines, maxChunkLines: maxChunkLines)
        chunks.append(contentsOf: subChunks)
      }
    }

    return chunks
  }

  // MARK: - Tree-sitter Parsing

  private func parseSource(_ source: String) -> OpaquePointer? /* TSTree */ {
    let parser = ts_parser_new()
    guard let parser else { return nil }
    defer { ts_parser_delete(parser) }

    let language = tree_sitter_glimmer_typescript()
    guard ts_parser_set_language(parser, language) else {
      return nil
    }

    let tree = source.withCString { cString in
      ts_parser_parse_string(parser, nil, cString, UInt32(strlen(cString)))
    }

    return tree
  }

  // MARK: - Construct Extraction

  private struct ParsedConstruct {
    let type: ASTChunk.ConstructType
    let name: String?
    let startLine: Int  // 0-indexed
    let endLine: Int    // 0-indexed
    // Inheritance facts (#745): RAGCore maps superclass → refKind "inherit"
    // and protocols → refKind "conform"; before these were threaded through,
    // every Ember class chunk produced zero conform/inherit symbol refs.
    var superclass: String? = nil
    var protocols: [String] = []
  }

  private func extractTopLevelConstructs(_ rootNode: TSNode, sourceLines: [String]) -> [ParsedConstruct] {
    var constructs: [ParsedConstruct] = []
    let childCount = ts_node_named_child_count(rootNode)

    var importStartLine: Int?
    var importEndLine: Int?

    for i in 0..<childCount {
      let child = ts_node_named_child(rootNode, i)
      let nodeType = String(cString: ts_node_type(child))
      let startRow = Int(ts_node_start_point(child).row)
      let endRow = Int(ts_node_end_point(child).row)

      if nodeType == "import_statement" {
        // Group consecutive imports
        if importStartLine == nil {
          importStartLine = startRow
        }
        importEndLine = endRow
        continue
      }

      // Flush any accumulated imports
      if let start = importStartLine, let end = importEndLine {
        constructs.append(ParsedConstruct(type: .imports, name: "imports", startLine: start, endLine: end))
        importStartLine = nil
        importEndLine = nil
      }

      // Map the node
      if let construct = mapNode(child, nodeType: nodeType, startRow: startRow, endRow: endRow, sourceLines: sourceLines) {
        constructs.append(construct)
      }
    }

    // Flush trailing imports
    if let start = importStartLine, let end = importEndLine {
      constructs.append(ParsedConstruct(type: .imports, name: "imports", startLine: start, endLine: end))
    }

    return constructs
  }

  private func mapNode(_ node: TSNode, nodeType: String, startRow: Int, endRow: Int, sourceLines: [String]) -> ParsedConstruct? {
    switch nodeType {
    case "class_declaration":
      let name = extractName(node, sourceLines: sourceLines, patterns: [#"class\s+(\w+)"#])
      // The class header may wrap (`class Foo\n  extends Component`); scan
      // the first few lines of the declaration for inheritance facts.
      let header = extractLines(from: sourceLines, start: startRow, end: min(startRow + 3, endRow))
      return ParsedConstruct(
        type: .classDecl, name: name, startLine: startRow, endLine: endRow,
        superclass: extractSuperclass(from: header),
        protocols: extractImplements(from: header)
      )

    case "function_declaration":
      let name = extractName(node, sourceLines: sourceLines, patterns: [#"function\s+(\w+)"#])
      return ParsedConstruct(type: .function, name: name, startLine: startRow, endLine: endRow)

    case "interface_declaration":
      let name = extractName(node, sourceLines: sourceLines, patterns: [#"interface\s+(\w+)"#])
      return ParsedConstruct(type: .protocolDecl, name: name, startLine: startRow, endLine: endRow)

    case "type_alias_declaration":
      let name = extractName(node, sourceLines: sourceLines, patterns: [#"type\s+(\w+)"#])
      return ParsedConstruct(type: .protocolDecl, name: name, startLine: startRow, endLine: endRow)

    case "enum_declaration":
      let name = extractName(node, sourceLines: sourceLines, patterns: [#"enum\s+(\w+)"#])
      return ParsedConstruct(type: .enumDecl, name: name, startLine: startRow, endLine: endRow)

    case "lexical_declaration":
      // const/let at top level — check if it's a component or function
      let name = extractName(node, sourceLines: sourceLines, patterns: [#"(?:const|let)\s+(\w+)"#])
      let constructType = classifyLexicalDeclaration(node, startRow: startRow, endRow: endRow, sourceLines: sourceLines)
      return ParsedConstruct(type: constructType, name: name, startLine: startRow, endLine: endRow)

    case "export_statement":
      // Recurse into the exported declaration
      let innerCount = ts_node_named_child_count(node)
      for i in 0..<innerCount {
        let inner = ts_node_named_child(node, i)
        let innerType = String(cString: ts_node_type(inner))
        if let mapped = mapNode(inner, nodeType: innerType, startRow: startRow, endRow: endRow, sourceLines: sourceLines) {
          return mapped
        }
      }
      return nil

    case "glimmer_template":
      // Standalone <template> block (template-only component)
      return ParsedConstruct(type: .component, name: nil, startLine: startRow, endLine: endRow)

    case "comment":
      // Skip standalone comments
      return nil

    default:
      return nil
    }
  }

  /// Classify a lexical_declaration (const/let) as component, function, or file
  private func classifyLexicalDeclaration(_ node: TSNode, startRow: Int, endRow: Int, sourceLines: [String]) -> ASTChunk.ConstructType {
    // Check child nodes for indicators
    let text = extractLines(from: sourceLines, start: startRow, end: min(startRow + 5, endRow))

    // Check if it contains a template (Glimmer component)
    if text.contains("<template") || text.contains("__TEMPLATE_PLACEHOLDER__") {
      return .component
    }

    // Check for TOC<> (template-only component)
    if text.contains("TOC<") || text.contains("TemplateOnlyComponent") {
      return .component
    }

    // Check for arrow function or function expression
    if text.contains("=>") || text.contains("function(") || text.contains("function (") {
      return .function
    }

    // Default: treat as file-level declaration
    return .file
  }

  // MARK: - Inheritance Extraction (#745)

  /// `class Foo extends Component<Sig>` → "Component". Dotted bases
  /// (`extends Foo.Bar`) keep the full dotted name.
  private func extractSuperclass(from header: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: #"\bextends\s+([A-Za-z_$][\w$.]*)"#),
          let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
          let range = Range(match.range(at: 1), in: header) else { return nil }
    return String(header[range])
  }

  /// `implements A, B<T>` → ["A", "B"]. Commas inside generic arguments
  /// don't separate interfaces: `implements Foo<A, B>, Bar` → ["Foo", "Bar"].
  private func extractImplements(from header: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: #"\bimplements\s+([^{\n]+)"#),
          let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
          let range = Range(match.range(at: 1), in: header) else { return [] }
    return splitAtTopLevelCommas(String(header[range]))
      .compactMap { item in
        let base = item.trimmingCharacters(in: .whitespaces)
          .components(separatedBy: "<").first?
          .trimmingCharacters(in: .whitespaces) ?? ""
        return base.isEmpty ? nil : base
      }
  }

  /// Split on commas at angle-bracket depth 0 only.
  private func splitAtTopLevelCommas(_ clause: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var depth = 0
    for char in clause {
      switch char {
      case "<": depth += 1; current.append(char)
      case ">": depth = max(0, depth - 1); current.append(char)
      case "," where depth == 0:
        parts.append(current)
        current = ""
      default: current.append(char)
      }
    }
    parts.append(current)
    return parts
  }

  // MARK: - Name Extraction

  private func extractName(_ node: TSNode, sourceLines: [String], patterns: [String]) -> String? {
    let startRow = Int(ts_node_start_point(node).row)
    guard startRow < sourceLines.count else { return nil }
    let sourceLine = sourceLines[startRow]

    for pattern in patterns {
      if let regex = try? NSRegularExpression(pattern: pattern),
         let match = regex.firstMatch(in: sourceLine, range: NSRange(sourceLine.startIndex..., in: sourceLine)),
         let nameRange = Range(match.range(at: 1), in: sourceLine) {
        return String(sourceLine[nameRange])
      }
    }
    return nil
  }

  // MARK: - Chunk Splitting

  private func splitLargeConstruct(_ construct: ParsedConstruct, lines: [String], maxChunkLines: Int) -> [ASTChunk] {
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
        metadata: ASTChunkMetadata(
          // Inheritance facts only on the first part — symbol_refs dedupe
          // per file, but keeping one source avoids implying every part
          // re-declares the class.
          protocols: i == 0 ? construct.protocols : [],
          superclass: i == 0 ? construct.superclass : nil,
          typeReferences: extractTypeReferences(from: text)
        )
      ))
    }

    return chunks
  }

  // MARK: - Helpers

  private func extractLines(from lines: [String], start: Int, end: Int) -> String {
    guard start >= 0 && end < lines.count && start <= end else {
      return ""
    }
    return lines[start...end].joined(separator: "\n")
  }

  /// Extract type names referenced in source (shared logic with GlimmerChunker)
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
}
