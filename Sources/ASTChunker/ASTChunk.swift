//
//  ASTChunk.swift
//  ASTChunker
//
//  Represents a semantic chunk of code extracted via AST analysis.
//

import Foundation

/// Language-agnostic symbol metadata extracted from a chunk.
/// This is intentionally coarse for now: it normalizes construct definitions and
/// reference names across Swift, Ruby, and TypeScript-family chunkers without
/// requiring language-specific consumers to understand each parser.
public struct ASTSymbol: Sendable, Equatable, Codable {
  public enum Kind: String, Sendable, Codable, CaseIterable {
    case type
    case function
    case property
    case module
    case component
    case unknown
  }

  public let name: String
  public let kind: Kind
  public let language: String

  public init(name: String, kind: Kind, language: String) {
    self.name = name
    self.kind = kind
    self.language = language
  }
}

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
  
  /// Design-system component imports (e.g. @org/ui-kit)
  public var designSystemImports: [String]
  
  /// Frameworks detected (SwiftUI, Rails, Ember, etc.)
  public var frameworks: [String]
  
  // MARK: - Type Reference Tracking (for orphan detection)
  
  /// Type names referenced in this chunk (variable types, instantiations, static accesses)
  /// Used to track same-module dependencies that don't require imports
  public var typeReferences: [String]

  /// Normalized symbols defined by this chunk.
  /// Example: a Swift class chunk defines `UserService`, a Ruby module chunk defines `Authentication`.
  public var symbolDefinitions: [ASTSymbol]

  /// Normalized symbols referenced by this chunk.
  /// This currently derives from type-like references and will grow into a richer symbol graph.
  public var symbolReferences: [ASTSymbol]
  
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
    designSystemImports: [String] = [],
    frameworks: [String] = [],
    typeReferences: [String] = [],
    symbolDefinitions: [ASTSymbol] = [],
    symbolReferences: [ASTSymbol] = []
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
    self.designSystemImports = designSystemImports
    self.frameworks = frameworks
    self.typeReferences = typeReferences
    self.symbolDefinitions = symbolDefinitions
    self.symbolReferences = symbolReferences
  }

  private enum CodingKeys: String, CodingKey {
    case decorators
    case protocols
    case imports
    case superclass
    case propertyWrappers
    case mixins
    case callbacks
    case associations
    case usesEmberConcurrency
    case hasTemplate
    case designSystemImports
    case frameworks
    case typeReferences
    case symbolDefinitions
    case symbolReferences
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    decorators = try container.decodeIfPresent([String].self, forKey: .decorators) ?? []
    protocols = try container.decodeIfPresent([String].self, forKey: .protocols) ?? []
    imports = try container.decodeIfPresent([String].self, forKey: .imports) ?? []
    superclass = try container.decodeIfPresent(String.self, forKey: .superclass)
    propertyWrappers = try container.decodeIfPresent([String].self, forKey: .propertyWrappers) ?? []
    mixins = try container.decodeIfPresent([String].self, forKey: .mixins) ?? []
    callbacks = try container.decodeIfPresent([String].self, forKey: .callbacks) ?? []
    associations = try container.decodeIfPresent([String].self, forKey: .associations) ?? []
    usesEmberConcurrency = try container.decodeIfPresent(Bool.self, forKey: .usesEmberConcurrency) ?? false
    hasTemplate = try container.decodeIfPresent(Bool.self, forKey: .hasTemplate) ?? false
    designSystemImports = try container.decodeIfPresent([String].self, forKey: .designSystemImports) ?? []
    frameworks = try container.decodeIfPresent([String].self, forKey: .frameworks) ?? []
    typeReferences = try container.decodeIfPresent([String].self, forKey: .typeReferences) ?? []
    symbolDefinitions = try container.decodeIfPresent([ASTSymbol].self, forKey: .symbolDefinitions) ?? []
    symbolReferences = try container.decodeIfPresent([ASTSymbol].self, forKey: .symbolReferences) ?? []
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(decorators, forKey: .decorators)
    try container.encode(protocols, forKey: .protocols)
    try container.encode(imports, forKey: .imports)
    try container.encodeIfPresent(superclass, forKey: .superclass)
    try container.encode(propertyWrappers, forKey: .propertyWrappers)
    try container.encode(mixins, forKey: .mixins)
    try container.encode(callbacks, forKey: .callbacks)
    try container.encode(associations, forKey: .associations)
    try container.encode(usesEmberConcurrency, forKey: .usesEmberConcurrency)
    try container.encode(hasTemplate, forKey: .hasTemplate)
    try container.encode(designSystemImports, forKey: .designSystemImports)
    try container.encode(frameworks, forKey: .frameworks)
    try container.encode(typeReferences, forKey: .typeReferences)
    try container.encode(symbolDefinitions, forKey: .symbolDefinitions)
    try container.encode(symbolReferences, forKey: .symbolReferences)
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
    !designSystemImports.isEmpty ||
    !frameworks.isEmpty ||
    !typeReferences.isEmpty ||
    !symbolDefinitions.isEmpty ||
    !symbolReferences.isEmpty
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
    self.metadata = metadata.withNormalizedSymbols(
      constructType: constructType,
      constructName: constructName,
      language: language
    )
  }
}

public extension ASTChunkMetadata {
  func withNormalizedSymbols(
    constructType: ASTChunk.ConstructType,
    constructName: String?,
    language: String
  ) -> ASTChunkMetadata {
    var copy = self

    if copy.symbolDefinitions.isEmpty,
       let definition = normalizedDefinitionSymbol(
        constructType: constructType,
        constructName: constructName,
        language: language
       ) {
      copy.symbolDefinitions = [definition]
    }

    if copy.symbolReferences.isEmpty, !copy.typeReferences.isEmpty {
      copy.symbolReferences = copy.typeReferences.map {
        ASTSymbol(name: $0, kind: .unknown, language: language)
      }
    }

    return copy
  }

  private func normalizedDefinitionSymbol(
    constructType: ASTChunk.ConstructType,
    constructName: String?,
    language: String
  ) -> ASTSymbol? {
    guard let constructName, !constructName.isEmpty else {
      return nil
    }

    let symbolKind: ASTSymbol.Kind
    switch constructType {
    case .classDecl, .structDecl, .enumDecl, .protocolDecl, .extension, .actorDecl:
      symbolKind = .type
    case .function, .method:
      symbolKind = .function
    case .property:
      symbolKind = .property
    case .module:
      symbolKind = .module
    case .component:
      symbolKind = .component
    case .file, .imports, .unknown:
      symbolKind = .unknown
    }

    guard symbolKind != .unknown else {
      return nil
    }

    return ASTSymbol(name: constructName, kind: symbolKind, language: language)
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
