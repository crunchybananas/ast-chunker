//
//  ASTChunk.swift
//  ASTChunker
//
//  Represents a semantic chunk of code extracted via AST analysis.
//

import Foundation

/// Structured metadata extracted from AST analysis for improved RAG search
public struct ASTChunkMetadata: Sendable, Equatable, Codable {
  // MARK: - Universal Metadata
  
  /// Decorators/attributes applied to the construct (e.g., @MainActor, @Observable, @tracked)
  public var decorators: [String]
  
  /// Protocols/interfaces this construct conforms to (Swift: protocols, TS: interfaces)
  public var protocols: [String]
  
  /// Import statements relevant to this chunk
  public var imports: [String]
  
  /// Superclass name (for classes with inheritance)
  public var superclass: String?
  
  // MARK: - Swift-Specific
  
  /// Property wrappers used (e.g., @State, @Environment, @AppStorage)
  public var propertyWrappers: [String]
  
  // MARK: - Ruby-Specific
  
  /// Included modules/mixins (Ruby: include, extend, prepend)
  public var mixins: [String]
  
  /// Callback methods (Rails: before_action, after_create, etc.)
  public var callbacks: [String]
  
  /// ActiveRecord associations (has_many, belongs_to, etc.)
  public var associations: [String]
  
  // MARK: - TypeScript/Ember-Specific
  
  /// Whether this uses ember-concurrency patterns
  public var usesEmberConcurrency: Bool
  
  /// Whether this file contains a Glimmer <template> block
  public var hasTemplate: Bool
  
  /// TIO-UI component imports (for tio-front-end)
  public var tioUiImports: [String]
  
  /// Frameworks detected (SwiftUI, Rails, Ember, etc.)
  public var frameworks: [String]
  
  // MARK: - Type Reference Tracking (for orphan detection)
  
  /// Type names referenced in this chunk (variable types, instantiations, static accesses)
  /// Used to track same-module dependencies that don't require imports
  public var typeReferences: [String]
  
  public init(
    decorators: [String] = [],
    protocols: [String] = [],
    imports: [String] = [],
    superclass: String? = nil,
    propertyWrappers: [String] = [],
    mixins: [String] = [],
    callbacks: [String] = [],
    associations: [String] = [],
    usesEmberConcurrency: Bool = false,
    hasTemplate: Bool = false,
    tioUiImports: [String] = [],
    frameworks: [String] = [],
    typeReferences: [String] = []
  ) {
    self.decorators = decorators
    self.protocols = protocols
    self.imports = imports
    self.superclass = superclass
    self.propertyWrappers = propertyWrappers
    self.mixins = mixins
    self.callbacks = callbacks
    self.associations = associations
    self.usesEmberConcurrency = usesEmberConcurrency
    self.hasTemplate = hasTemplate
    self.tioUiImports = tioUiImports
    self.frameworks = frameworks
    self.typeReferences = typeReferences
  }
  
  /// Returns true if this metadata has any non-empty fields
  public var hasContent: Bool {
    !decorators.isEmpty ||
    !protocols.isEmpty ||
    !imports.isEmpty ||
    superclass != nil ||
    !propertyWrappers.isEmpty ||
    !mixins.isEmpty ||
    !callbacks.isEmpty ||
    !associations.isEmpty ||
    usesEmberConcurrency ||
    hasTemplate ||
    !tioUiImports.isEmpty ||
    !frameworks.isEmpty ||
    !typeReferences.isEmpty
  }
  
  /// JSON representation for database storage
  public func toJSON() -> String? {
    guard hasContent else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard let data = try? encoder.encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }
  
  /// Parse from JSON string
  public static func fromJSON(_ json: String) -> ASTChunkMetadata? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(ASTChunkMetadata.self, from: data)
  }
}

/// A semantic chunk extracted from source code using AST analysis
public struct ASTChunk: Sendable, Equatable {
  /// The type of code construct this chunk represents
  public enum ConstructType: String, Sendable, CaseIterable {
    case file           // Entire file or fallback chunk
    case imports        // Import block
    case classDecl      // Class definition
    case structDecl     // Struct definition
    case enumDecl       // Enum definition
    case protocolDecl   // Protocol definition
    case `extension`    // Extension
    case actorDecl      // Actor definition
    case function       // Top-level function
    case method         // Method within a type
    case property       // Computed property (if large)
    case module         // Ruby/Python module
    case component      // UI Component (Ember/React)
    case unknown
  }
  
  /// The construct type
  public let constructType: ConstructType
  
  /// Name of the construct (e.g., "MyClass", "MyClass.loadData")
  public let constructName: String?
  
  /// 1-indexed start line in the source file
  public let startLine: Int
  
  /// 1-indexed end line in the source file (inclusive)
  public let endLine: Int
  
  /// The actual source text of this chunk
  public let text: String
  
  /// Language identifier (e.g., "swift", "ruby", "typescript")
  public let language: String
  
  /// Structured metadata extracted from AST (decorators, protocols, imports, etc.)
  public let metadata: ASTChunkMetadata
  
  /// Number of lines in this chunk
  public var lineCount: Int {
    endLine - startLine + 1
  }
  
  /// Estimated token count for embedding budget (~4 chars per token for code)
  public var estimatedTokenCount: Int {
    max(1, text.count / 4)
  }
  
  public init(
    constructType: ConstructType,
    constructName: String?,
    startLine: Int,
    endLine: Int,
    text: String,
    language: String,
    metadata: ASTChunkMetadata = ASTChunkMetadata()
  ) {
    self.constructType = constructType
    self.constructName = constructName
    self.startLine = startLine
    self.endLine = endLine
    self.text = text
    self.language = language
    self.metadata = metadata
  }
}

extension ASTChunk: CustomStringConvertible {
  public var description: String {
    let name = constructName ?? "<anonymous>"
    var desc = "\(constructType.rawValue): \(name) (lines \(startLine)-\(endLine))"
    if !metadata.decorators.isEmpty {
      desc += " [\(metadata.decorators.joined(separator: ", "))]"
    }
    if !metadata.protocols.isEmpty {
      desc += " : \(metadata.protocols.joined(separator: ", "))"
    }
    return desc
  }
}
