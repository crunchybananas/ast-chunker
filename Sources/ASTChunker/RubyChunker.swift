//
//  RubyChunker.swift
//  ASTChunker
//
//  Ruby AST chunker using tree-sitter for parsing.
//

import Foundation

/// Ruby AST chunker using tree-sitter
public struct RubyChunker: LanguageChunker, Sendable {
  public static let language = "ruby"
  public static let fileExtensions: Set<String> = ["rb", "rake", "gemspec", "ru"]
  
  /// Path to tree-sitter dynamic library for Ruby
  private let treeSitterLibPath: String
  
  /// Path to tree-sitter CLI
  private let treeSitterCLIPath: String
  
  public init(
    treeSitterLibPath: String = "~/code/tree-sitter-grammars/tree-sitter-ruby/ruby.dylib",
    treeSitterCLIPath: String = "/opt/homebrew/bin/tree-sitter"
  ) {
    self.treeSitterLibPath = (treeSitterLibPath as NSString).expandingTildeInPath
    self.treeSitterCLIPath = treeSitterCLIPath
  }
  
  public func chunk(source: String, maxChunkLines: Int = 200) -> [ASTChunk] {
    // Write source to temp file
    let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("ruby_\(UUID().uuidString).rb")
    
    do {
      try source.write(to: tempFile, atomically: true, encoding: .utf8)
      defer { try? FileManager.default.removeItem(at: tempFile) }
      
      // Parse with tree-sitter
      guard let ast = parseWithTreeSitter(file: tempFile.path) else {
        return fallbackChunk(source: source)
      }
      
      // Extract chunks from AST
      let chunks = extractChunks(from: ast, source: source, maxChunkLines: maxChunkLines)
      return chunks.isEmpty ? fallbackChunk(source: source) : chunks
      
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
      "--lang-name", "ruby",
      "--timeout", "3000000",  // 3 seconds in microseconds
      file
    ]
    process.standardOutput = pipe
    process.standardError = errorPipe
    
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
      
      return String(data: outputData, encoding: .utf8)
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
      // Extract metadata from source
      let metadata = extractRubyMetadata(from: lines, construct: construct)
      
      if construct.endLine - construct.startLine + 1 <= maxChunkLines {
        // Construct fits in one chunk
        let text = extractLines(from: lines, start: construct.startLine, end: construct.endLine)
        chunks.append(ASTChunk(
          constructType: construct.type,
          constructName: construct.name,
          startLine: construct.startLine + 1, // Convert to 1-indexed
          endLine: construct.endLine + 1,
          text: text,
          language: Self.language,
          metadata: metadata
        ))
      } else {
        // Split large construct by methods
        let methodChunks = splitByMethods(construct: construct, ast: ast, lines: lines, maxChunkLines: maxChunkLines, metadata: metadata)
        chunks.append(contentsOf: methodChunks)
      }
    }
    
    return chunks
  }
  
  // MARK: - Ruby Metadata Extraction
  
  /// Extract Ruby-specific metadata from source lines
  private func extractRubyMetadata(from lines: [String], construct: ParsedConstruct) -> ASTChunkMetadata {
    var superclass: String? = nil
    var mixins: [String] = []
    var callbacks: [String] = []
    var associations: [String] = []
    var frameworks: [String] = []
    
    // Only extract metadata for classes/modules
    guard construct.type == .classDecl || construct.type == .module else {
      return ASTChunkMetadata()
    }
    
    let startLine = construct.startLine
    let endLine = min(construct.endLine, startLine + 50) // Only scan first 50 lines for metadata
    
    for lineIdx in startLine...endLine {
      guard lineIdx < lines.count else { break }
      let line = lines[lineIdx].trimmingCharacters(in: .whitespaces)
      
      // Extract superclass: class Foo < Bar
      if lineIdx == startLine, let superclassName = extractSuperclass(from: line) {
        superclass = superclassName
        
        // Detect Rails framework from common superclasses
        let railsControllers = ["ApplicationController", "ActionController::Base", "ActionController::API"]
        let railsModels = ["ApplicationRecord", "ActiveRecord::Base"]
        let railsJobs = ["ApplicationJob", "ActiveJob::Base"]
        let railsMailers = ["ApplicationMailer", "ActionMailer::Base"]
        
        if railsControllers.contains(superclassName) {
          frameworks.append("Rails")
          frameworks.append("ActionController")
        } else if railsModels.contains(superclassName) {
          frameworks.append("Rails")
          frameworks.append("ActiveRecord")
        } else if railsJobs.contains(superclassName) {
          frameworks.append("Rails")
          frameworks.append("ActiveJob")
        } else if railsMailers.contains(superclassName) {
          frameworks.append("Rails")
          frameworks.append("ActionMailer")
        }
      }
      
      // Extract mixins: include, extend, prepend
      if let mixin = extractMixin(from: line) {
        mixins.append(mixin)
      }
      
      // Extract Rails callbacks
      if let callback = extractCallback(from: line) {
        callbacks.append(callback)
      }
      
      // Extract ActiveRecord associations
      if let association = extractAssociation(from: line) {
        associations.append(association)
      }
    }
    
    return ASTChunkMetadata(
      superclass: superclass,
      mixins: mixins,
      callbacks: callbacks,
      associations: associations,
      frameworks: Array(Set(frameworks)).sorted()
    )
  }
  
  /// Extract superclass from class declaration line
  private func extractSuperclass(from line: String) -> String? {
    // Match: class ClassName < SuperClassName
    let pattern = #"class\s+\w+\s*<\s*([A-Z][\w:]*)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let superclassRange = Range(match.range(at: 1), in: line) else {
      return nil
    }
    return String(line[superclassRange])
  }
  
  /// Extract mixin from include/extend/prepend statements
  private func extractMixin(from line: String) -> String? {
    // Match: include ModuleName or extend ModuleName or prepend ModuleName
    let pattern = #"^\s*(include|extend|prepend)\s+([A-Z][\w:]*)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let moduleRange = Range(match.range(at: 2), in: line) else {
      return nil
    }
    return String(line[moduleRange])
  }
  
  /// Extract Rails callback from before_action, after_create, etc.
  private func extractCallback(from line: String) -> String? {
    // Common Rails callbacks
    let callbackPattern = #"^\s*(before_action|after_action|around_action|before_create|after_create|before_save|after_save|before_update|after_update|before_destroy|after_destroy|before_validation|after_validation|after_commit|after_rollback|after_initialize|after_find)\b"#
    guard let regex = try? NSRegularExpression(pattern: callbackPattern),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let callbackRange = Range(match.range(at: 1), in: line) else {
      return nil
    }
    return String(line[callbackRange])
  }
  
  /// Extract ActiveRecord association
  private func extractAssociation(from line: String) -> String? {
    // Match: has_many :items, belongs_to :user, has_one :profile, has_and_belongs_to_many :tags
    let pattern = #"^\s*(has_many|belongs_to|has_one|has_and_belongs_to_many)\s+:(\w+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let typeRange = Range(match.range(at: 1), in: line),
          let nameRange = Range(match.range(at: 2), in: line) else {
      return nil
    }
    let assocType = String(line[typeRange])
    let assocName = String(line[nameRange])
    return "\(assocType) :\(assocName)"
  }
  
  private struct ParsedConstruct {
    let type: ASTChunk.ConstructType
    let name: String?
    let startLine: Int  // 0-indexed
    let endLine: Int    // 0-indexed
  }
  
  private func parseTopLevelConstructs(from ast: String, sourceLines: [String]) -> [ParsedConstruct] {
    var constructs: [ParsedConstruct] = []
    let lines = ast.components(separatedBy: "\n")
    
    // Scan for class/module declarations and extract their info
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      
      // Match: (class [0, 0] - [15, 3] or (module [0, 0] - [10, 3]
      if let match = parseClassOrModuleLine(trimmed) {
        // Extract name from the source code at startLine
        let name = extractNameFromSource(sourceLines: sourceLines, line: match.startLine, type: match.type)
        
        constructs.append(ParsedConstruct(
          type: mapConstructType(match.type),
          name: name,
          startLine: match.startLine,
          endLine: match.endLine
        ))
      }
    }
    
    return constructs
  }
  
  private func parseClassOrModuleLine(_ line: String) -> (type: String, startLine: Int, endLine: Int)? {
    // Match: (class [0, 0] - [15, 3] or (module [0, 0] - [10, 3]
    // Only match at start of line (top-level)
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
    
    // Only care about class and module
    guard type == "class" || type == "module" else { return nil }
    
    let startLine = Int(line[startRange]) ?? 0
    let endLine = Int(line[endRange]) ?? 0
    
    return (type: type, startLine: startLine, endLine: endLine)
  }
  
  private func extractNameFromSource(sourceLines: [String], line: Int, type: String) -> String? {
    guard line < sourceLines.count else { return nil }
    
    let sourceLine = sourceLines[line]
    
    // Match: class ClassName or module ModuleName
    // Also handle: class ClassName < ParentClass
    let pattern: String
    switch type {
    case "class":
      pattern = #"class\s+([A-Z]\w*)"#
    case "module":
      pattern = #"module\s+([A-Z]\w*)"#
    default:
      return nil
    }
    
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: sourceLine, range: NSRange(sourceLine.startIndex..., in: sourceLine)),
          let nameRange = Range(match.range(at: 1), in: sourceLine) else {
      return nil
    }
    
    return String(sourceLine[nameRange])
  }
  
  private func mapConstructType(_ type: String) -> ASTChunk.ConstructType {
    switch type {
    case "class": return .classDecl
    case "module": return .module
    case "method", "singleton_method": return .method
    case "call": return .function  // method calls at top level
    default: return .unknown
    }
  }
  
  private func splitByMethods(construct: ParsedConstruct, ast: String, lines: [String], maxChunkLines: Int, metadata: ASTChunkMetadata) -> [ASTChunk] {
    // For now, just split into fixed-size chunks
    // Full implementation would parse method boundaries from AST
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
        metadata: metadata
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
