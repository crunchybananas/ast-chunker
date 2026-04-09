//
//  SwiftTreeSitterChunker.swift
//  ASTChunker
//
//  Swift AST chunker using tree-sitter-swift for parsing.
//  Provides an alternative to SwiftSyntax with iterative parsing (no stack overflow risk).
//

import Foundation

/// Swift AST chunker using tree-sitter-swift
public struct SwiftTreeSitterChunker: LanguageChunker, Sendable {
  public static let language = "swift"
  public static let fileExtensions: Set<String> = ["swift"]

  /// Path to tree-sitter dynamic library for Swift
  private let treeSitterLibPath: String

  /// Path to tree-sitter CLI
  private let treeSitterCLIPath: String

  /// Whether the chunker is available (library and CLI exist)
  public let isAvailable: Bool

  /// Environment variable for Swift grammar library path
  public static let envLibPath = "AST_CHUNKER_SWIFT_LIB"

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
      ?? ("~/code/tree-sitter-grammars/tree-sitter-swift/swift.dylib" as NSString).expandingTildeInPath

    let resolvedCLIPath = treeSitterCLIPath
      ?? ProcessInfo.processInfo.environment[Self.envCLIPath]
      ?? GlimmerChunker.findTreeSitterCLI(searchPaths: Self.treeSitterCLISearchPaths)

    self.treeSitterLibPath = (resolvedLibPath as NSString).expandingTildeInPath
    self.treeSitterCLIPath = resolvedCLIPath ?? ""
    self.isAvailable = !self.treeSitterLibPath.isEmpty &&
                       !self.treeSitterCLIPath.isEmpty &&
                       FileManager.default.fileExists(atPath: self.treeSitterLibPath) &&
                       FileManager.default.fileExists(atPath: self.treeSitterCLIPath)
  }

  public func chunk(source: String, maxChunkLines: Int = 150) -> [ASTChunk] {
    guard isAvailable else {
      return fallbackChunk(source: source)
    }

    let tempFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("swift_\(UUID().uuidString).swift")

    do {
      try source.write(to: tempFile, atomically: true, encoding: .utf8)
      defer { try? FileManager.default.removeItem(at: tempFile) }

      guard let ast = parseWithTreeSitter(file: tempFile.path) else {
        return fallbackChunk(source: source)
      }

      let chunks = extractChunks(from: ast, source: source, maxChunkLines: maxChunkLines)
      return chunks.isEmpty ? fallbackChunk(source: source) : chunks
    } catch {
      return fallbackChunk(source: source)
    }
  }

  // MARK: - Tree-sitter Integration

  private let parseTimeout: TimeInterval = 5.0

  private func parseWithTreeSitter(file: String) -> String? {
    let process = Process()
    let pipe = Pipe()
    let errorPipe = Pipe()

    process.executableURL = URL(fileURLWithPath: treeSitterCLIPath)
    process.arguments = [
      "parse",
      "-l", treeSitterLibPath,
      "--lang-name", "swift",
      "--timeout", "3000000",  // 3 seconds in microseconds
      file
    ]
    process.standardOutput = pipe
    process.standardError = errorPipe

    // Read output asynchronously to prevent pipe buffer deadlock on large AST outputs
    var outputData = Data()
    var errorData = Data()

    let outputHandle = pipe.fileHandleForReading
    let errorHandle = errorPipe.fileHandleForReading

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

      let result = group.wait(timeout: .now() + parseTimeout)

      if result == .timedOut {
        process.terminate()
        return nil
      }

      process.waitUntilExit()

      if process.terminationStatus != 0 {
        return nil
      }

      return String(data: outputData, encoding: .utf8)
    } catch {
      return nil
    }
  }

  // MARK: - AST Parsing

  private func extractChunks(from ast: String, source: String, maxChunkLines: Int) -> [ASTChunk] {
    let lines = source.components(separatedBy: "\n")
    var chunks: [ASTChunk] = []

    let constructs = parseTopLevelConstructs(from: ast, sourceLines: lines)

    for construct in constructs {
      let metadata = extractSwiftMetadata(from: lines, construct: construct)

      if construct.endLine - construct.startLine + 1 <= maxChunkLines {
        let text = extractLines(from: lines, start: construct.startLine, end: construct.endLine)
        var chunkMetadata = extractSwiftMetadata(from: lines, construct: construct)
        chunkMetadata.typeReferences = extractTypeReferences(from: text)
        chunks.append(ASTChunk(
          constructType: construct.type,
          constructName: construct.name,
          startLine: construct.startLine + 1,
          endLine: construct.endLine + 1,
          text: text,
          language: Self.language,
          metadata: chunkMetadata
        ))
      } else {
        // Split large construct into fixed-size chunks
        let subChunks = splitConstruct(construct: construct, lines: lines, maxChunkLines: maxChunkLines, metadata: metadata)
        chunks.append(contentsOf: subChunks)
      }
    }

    return chunks
  }

  // MARK: - Swift Metadata Extraction

  private func extractSwiftMetadata(from lines: [String], construct: ParsedConstruct) -> ASTChunkMetadata {
    var superclass: String? = nil
    var protocols: [String] = []
    var frameworks: [String] = []
    var imports: [String] = []
    var decorators: [String] = []

    // Scan for imports at the top of the file
    for lineIdx in 0..<min(lines.count, 50) {
      let line = lines[lineIdx].trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("import ") {
        let importName = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        imports.append(importName)
      }
    }

    // Detect common frameworks
    let frameworkMap: [String: String] = [
      "SwiftUI": "SwiftUI", "UIKit": "UIKit", "AppKit": "AppKit",
      "Combine": "Combine", "Foundation": "Foundation", "SwiftData": "SwiftData"
    ]
    for (importName, framework) in frameworkMap {
      if imports.contains(importName) {
        frameworks.append(framework)
      }
    }

    let startLine = construct.startLine
    guard startLine < lines.count else {
      return ASTChunkMetadata(protocols: protocols, imports: imports, superclass: superclass, frameworks: frameworks)
    }

    let declLine = lines[startLine].trimmingCharacters(in: .whitespaces)

    // Extract superclass and protocol conformances from declaration line
    // e.g. class Foo: Bar, SomeProtocol or struct Foo: SomeProtocol
    let inheritancePattern = #"(?:class|struct|enum|actor|extension)\s+\w+\s*(?:<[^>]*>)?\s*:\s*([A-Za-z][^{]*)"#
    if let regex = try? NSRegularExpression(pattern: inheritancePattern),
       let match = regex.firstMatch(in: declLine, range: NSRange(declLine.startIndex..., in: declLine)),
       let inheritanceRange = Range(match.range(at: 1), in: declLine) {
      let inheritanceList = String(declLine[inheritanceRange])
        .components(separatedBy: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

      // First item after colon for class is superclass if it starts with uppercase
      // and isn't a protocol marker (protocols typically start uppercase too, but
      // we use heuristics: if construct is a class and first item is capitalized)
      if construct.type == .classDecl, let first = inheritanceList.first {
        let name = first.components(separatedBy: .whitespaces).first ?? first
        // Common protocol patterns include 'Protocol' suffix or known protocols
        superclass = name
        protocols = Array(inheritanceList.dropFirst())
      } else {
        protocols = inheritanceList
      }
    }

    // Scan for decorators/attributes in the lines just before the declaration
    let decoratorStart = max(0, startLine - 5)
    for lineIdx in decoratorStart..<startLine {
      let line = lines[lineIdx].trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("@") {
        let decorator = line.components(separatedBy: "(").first ?? line
        decorators.append(decorator)
      }
    }

    return ASTChunkMetadata(
      decorators: decorators,
      protocols: protocols,
      imports: imports,
      superclass: superclass,
      frameworks: Array(Set(frameworks)).sorted()
    )
  }

  // MARK: - Type Reference Extraction

  private func extractTypeReferences(from text: String) -> [String] {
    var refs = Set<String>()
    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)

    let swiftBuiltins: Set<String> = [
      "String", "Int", "Double", "Float", "Bool", "Void", "Never",
      "Optional", "Array", "Dictionary", "Set", "Range", "ClosedRange",
      "Error", "Swift", "Foundation", "Any", "AnyObject", "Self",
      "Data", "Date", "URL", "UUID", "Result", "Codable", "Hashable",
      "Equatable", "Comparable", "Identifiable", "Sendable"
    ]

    let patterns: [(String, Int)] = [
      // Type inheritance: class Foo: Bar or struct Foo: Bar, Baz
      (#"(?:class|struct|actor|enum)\s+\w+\s*(?:<[^>]*)?\s*:\s*([A-Z]\w+)"#, 1),
      // Extension conformance: extension Foo: SomeProtocol
      (#"extension\s+\w+\s*:\s*([A-Z]\w+)"#, 1),
      // Generic constraints: where T: SomeProtocol
      (#"where\s+\w+\s*:\s*([A-Z]\w+)"#, 1),
      // Type instantiation: SomeClass()
      (#"\b([A-Z]\w+)\s*\("# , 1),
      // Static access: SomeClass.self or SomeClass.init
      (#"\b([A-Z]\w+)\s*\.\s*(?:self|init|shared)"#, 1),
    ]

    for (pattern, group) in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let matches = regex.matches(in: text, range: fullRange)
      for match in matches {
        guard match.numberOfRanges > group else { continue }
        let range = match.range(at: group)
        guard range.location != NSNotFound else { continue }
        let captured = nsText.substring(with: range)
        if !swiftBuiltins.contains(captured) && !captured.isEmpty {
          refs.insert(captured)
        }
      }
    }

    return refs.sorted()
  }

  // MARK: - Construct Parsing

  private struct ParsedConstruct {
    let type: ASTChunk.ConstructType
    let name: String?
    let startLine: Int  // 0-indexed
    let endLine: Int    // 0-indexed
  }

  private func parseTopLevelConstructs(from ast: String, sourceLines: [String]) -> [ParsedConstruct] {
    var constructs: [ParsedConstruct] = []
    let astLines = ast.components(separatedBy: "\n")

    for line in astLines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let match = parseSwiftConstructLine(trimmed) {
        let name = extractNameFromSource(sourceLines: sourceLines, lineIndex: match.startLine, nodeType: match.nodeType)
        constructs.append(ParsedConstruct(
          type: mapConstructType(match.nodeType),
          name: name,
          startLine: match.startLine,
          endLine: match.endLine
        ))
      }
    }

    return constructs
  }

  private func parseSwiftConstructLine(_ line: String) -> (nodeType: String, startLine: Int, endLine: Int)? {
    // Match tree-sitter output: (class_declaration [0, 0] - [15, 1]
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

    let nodeType = String(line[typeRange])

    let supportedTypes: Set<String> = [
      "class_declaration", "struct_declaration", "protocol_declaration",
      "enum_declaration", "extension_declaration", "function_declaration",
      "actor_declaration"
    ]
    guard supportedTypes.contains(nodeType) else { return nil }

    guard let startLine = Int(line[startRange]),
          let endLine = Int(line[endRange]) else {
      return nil
    }

    return (nodeType: nodeType, startLine: startLine, endLine: endLine)
  }

  private func extractNameFromSource(sourceLines: [String], lineIndex: Int, nodeType: String) -> String? {
    guard lineIndex < sourceLines.count else { return nil }
    let line = sourceLines[lineIndex]

    let keyword: String
    switch nodeType {
    case "class_declaration": keyword = "class"
    case "struct_declaration": keyword = "struct"
    case "protocol_declaration": keyword = "protocol"
    case "enum_declaration": keyword = "enum"
    case "extension_declaration": keyword = "extension"
    case "function_declaration": keyword = "func"
    case "actor_declaration": keyword = "actor"
    default: return nil
    }

    let pattern = "\(keyword)\\s+([A-Za-z_][\\w]*)"
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let nameRange = Range(match.range(at: 1), in: line) else {
      return nil
    }
    return String(line[nameRange])
  }

  private func mapConstructType(_ nodeType: String) -> ASTChunk.ConstructType {
    switch nodeType {
    case "class_declaration": return .classDecl
    case "struct_declaration": return .structDecl
    case "protocol_declaration": return .protocolDecl
    case "enum_declaration": return .enumDecl
    case "extension_declaration": return .extension
    case "function_declaration": return .function
    case "actor_declaration": return .actorDecl
    default: return .unknown
    }
  }

  private func splitConstruct(construct: ParsedConstruct, lines: [String], maxChunkLines: Int, metadata: ASTChunkMetadata) -> [ASTChunk] {
    var chunks: [ASTChunk] = []
    var currentStart = construct.startLine

    while currentStart <= construct.endLine {
      let currentEnd = min(currentStart + maxChunkLines - 1, construct.endLine)
      let text = extractLines(from: lines, start: currentStart, end: currentEnd)

      chunks.append(ASTChunk(
        constructType: construct.type,
        constructName: construct.name,
        startLine: currentStart + 1,
        endLine: currentEnd + 1,
        text: text,
        language: Self.language,
        metadata: ASTChunkMetadata(
          decorators: metadata.decorators,
          protocols: metadata.protocols,
          imports: metadata.imports,
          superclass: metadata.superclass,
          frameworks: metadata.frameworks,
          typeReferences: extractTypeReferences(from: text)
        )
      ))

      currentStart = currentEnd + 1
    }

    return chunks
  }

  private func extractLines(from lines: [String], start: Int, end: Int) -> String {
    let safeStart = max(0, start)
    let safeEnd = min(lines.count - 1, end)
    guard safeStart <= safeEnd else { return "" }
    return lines[safeStart...safeEnd].joined(separator: "\n")
  }

  private func fallbackChunk(source: String) -> [ASTChunk] {
    let lineCount = source.components(separatedBy: "\n").count
    return [ASTChunk(
      constructType: .file,
      constructName: nil,
      startLine: 1,
      endLine: lineCount,
      text: source,
      language: Self.language
    )]
  }
}
