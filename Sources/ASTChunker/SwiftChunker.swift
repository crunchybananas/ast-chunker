//
//  SwiftChunker.swift
//  ASTChunker
//
//  AST-based chunker for Swift source files using SwiftSyntax.
//

import Foundation
import SwiftParser
import SwiftSyntax

/// AST-based chunker for Swift source files using Apple's SwiftSyntax
public struct SwiftChunker: LanguageChunker, Sendable {
  public static let language = "swift"
  public static let fileExtensions: Set<String> = ["swift"]
  
  public init() {}
  
  public func chunk(source: String, maxChunkLines: Int = 150) -> [ASTChunk] {
    let sourceFile = Parser.parse(source: source)
    let lineMap = LineMap(source: source)
    var chunks: [ASTChunk] = []
    
    // Collect imports for metadata
    var importStatements: [ImportDeclSyntax] = []
    var importNames: [String] = []
    
    // Process top-level statements
    for statement in sourceFile.statements {
      let item = statement.item
      
      // Collect imports to group them
      if let importDecl = item.as(ImportDeclSyntax.self) {
        importStatements.append(importDecl)
        // Extract import path (e.g., "Foundation", "SwiftUI")
        let importPath = importDecl.path.map { $0.name.text }.joined(separator: ".")
        importNames.append(importPath)
        continue
      }
      
      // Process declarations - try each declaration type
      processItem(
        item,
        lineMap: lineMap,
        maxChunkLines: maxChunkLines,
        chunks: &chunks,
        fileImports: importNames
      )
    }
    
    // Create import chunk if we have imports
    if !importStatements.isEmpty {
      let startLine = lineMap.line(for: importStatements.first!.position)
      let endLine = lineMap.line(for: importStatements.last!.endPosition)
      let text = lineMap.text(from: startLine, to: endLine)
      
      // Detect frameworks from imports
      let frameworks = detectFrameworks(from: importNames)
      
      chunks.insert(ASTChunk(
        constructType: .imports,
        constructName: nil,
        startLine: startLine,
        endLine: endLine,
        text: text,
        language: Self.language,
        metadata: ASTChunkMetadata(
          imports: importNames,
          frameworks: frameworks
        )
      ), at: 0)
    }
    
    // Sort by line number
    chunks.sort { $0.startLine < $1.startLine }
    
    // Fallback if no chunks
    if chunks.isEmpty && !source.isEmpty {
      return fallbackChunks(source: source, lineMap: lineMap, maxChunkLines: maxChunkLines)
    }
    
    return chunks
  }
  
  // MARK: - Framework Detection
  
  private func detectFrameworks(from imports: [String]) -> [String] {
    var frameworks: [String] = []
    
    let frameworkMapping: [String: String] = [
      "SwiftUI": "SwiftUI",
      "UIKit": "UIKit",
      "AppKit": "AppKit",
      "Combine": "Combine",
      "SwiftData": "SwiftData",
      "CoreData": "CoreData",
      "Foundation": "Foundation",
      "Observation": "Observation",
      "JavaScriptCore": "JavaScriptCore",
    ]
    
    for imp in imports {
      if let framework = frameworkMapping[imp] {
        frameworks.append(framework)
      }
    }
    
    return frameworks
  }
  
  // MARK: - Declaration Processing
  
  /// Process a code block item, checking for various declaration types
  private func processItem(
    _ item: CodeBlockItemSyntax.Item,
    lineMap: LineMap,
    maxChunkLines: Int,
    chunks: inout [ASTChunk],
    fileImports: [String]
  ) {
    // Try each declaration type we care about
    if let classDecl = item.as(ClassDeclSyntax.self) {
      processDeclaration(classDecl, lineMap: lineMap, maxChunkLines: maxChunkLines, chunks: &chunks, parentName: nil, fileImports: fileImports)
    } else if let structDecl = item.as(StructDeclSyntax.self) {
      processDeclaration(structDecl, lineMap: lineMap, maxChunkLines: maxChunkLines, chunks: &chunks, parentName: nil, fileImports: fileImports)
    } else if let enumDecl = item.as(EnumDeclSyntax.self) {
      processDeclaration(enumDecl, lineMap: lineMap, maxChunkLines: maxChunkLines, chunks: &chunks, parentName: nil, fileImports: fileImports)
    } else if let protocolDecl = item.as(ProtocolDeclSyntax.self) {
      processDeclaration(protocolDecl, lineMap: lineMap, maxChunkLines: maxChunkLines, chunks: &chunks, parentName: nil, fileImports: fileImports)
    } else if let extensionDecl = item.as(ExtensionDeclSyntax.self) {
      processDeclaration(extensionDecl, lineMap: lineMap, maxChunkLines: maxChunkLines, chunks: &chunks, parentName: nil, fileImports: fileImports)
    } else if let actorDecl = item.as(ActorDeclSyntax.self) {
      processDeclaration(actorDecl, lineMap: lineMap, maxChunkLines: maxChunkLines, chunks: &chunks, parentName: nil, fileImports: fileImports)
    } else if let funcDecl = item.as(FunctionDeclSyntax.self) {
      processDeclaration(funcDecl, lineMap: lineMap, maxChunkLines: maxChunkLines, chunks: &chunks, parentName: nil, fileImports: fileImports)
    }
    // Ignore other statement types (variables, expressions, etc.)
  }
  
  private func processDeclaration(
    _ decl: any DeclSyntaxProtocol,
    lineMap: LineMap,
    maxChunkLines: Int,
    chunks: inout [ASTChunk],
    parentName: String?,
    fileImports: [String]
  ) {
    let (constructType, name) = extractTypeAndName(from: decl)
    
    // Skip unknown declarations
    guard constructType != .unknown else { return }
    
    // Extract metadata from the declaration
    let metadata = extractMetadata(from: decl, fileImports: fileImports)
    
    // Use positionAfterSkippingLeadingTrivia to get actual declaration start (not leading whitespace)
    let startLine = lineMap.line(for: decl.positionAfterSkippingLeadingTrivia)
    let endLine = lineMap.line(for: decl.endPositionBeforeTrailingTrivia)
    let lineCount = endLine - startLine + 1
    let fullName = combineName(parent: parentName, child: name)
    
    if lineCount <= maxChunkLines {
      // Small enough - single chunk
      let text = lineMap.text(from: startLine, to: endLine)
      chunks.append(ASTChunk(
        constructType: constructType,
        constructName: fullName,
        startLine: startLine,
        endLine: endLine,
        text: text,
        language: Self.language,
        metadata: metadata
      ))
    } else {
      // Too large - split by members
      splitLargeDeclaration(
        decl,
        constructType: constructType,
        constructName: fullName,
        lineMap: lineMap,
        maxChunkLines: maxChunkLines,
        chunks: &chunks,
        metadata: metadata
      )
    }
  }
  
  // MARK: - Metadata Extraction
  
  /// Extract structured metadata from a Swift declaration
  private func extractMetadata(from decl: any DeclSyntaxProtocol, fileImports: [String]) -> ASTChunkMetadata {
    var decorators: [String] = []
    var protocols: [String] = []
    var propertyWrappers: [String] = []
    var superclass: String? = nil
    var frameworks: [String] = []
    
    // Extract attributes (decorators)
    if let withAttrs = decl.as(ClassDeclSyntax.self) {
      decorators = extractAttributes(from: withAttrs.attributes)
      (superclass, protocols) = extractInheritance(from: withAttrs.inheritanceClause)
    } else if let withAttrs = decl.as(StructDeclSyntax.self) {
      decorators = extractAttributes(from: withAttrs.attributes)
      (_, protocols) = extractInheritance(from: withAttrs.inheritanceClause)
    } else if let withAttrs = decl.as(EnumDeclSyntax.self) {
      decorators = extractAttributes(from: withAttrs.attributes)
      (_, protocols) = extractInheritance(from: withAttrs.inheritanceClause)
    } else if let withAttrs = decl.as(ActorDeclSyntax.self) {
      decorators = extractAttributes(from: withAttrs.attributes)
      (_, protocols) = extractInheritance(from: withAttrs.inheritanceClause)
    } else if let withAttrs = decl.as(ProtocolDeclSyntax.self) {
      decorators = extractAttributes(from: withAttrs.attributes)
      (_, protocols) = extractInheritance(from: withAttrs.inheritanceClause)
    } else if let withAttrs = decl.as(ExtensionDeclSyntax.self) {
      decorators = extractAttributes(from: withAttrs.attributes)
      (_, protocols) = extractInheritance(from: withAttrs.inheritanceClause)
    } else if let withAttrs = decl.as(FunctionDeclSyntax.self) {
      decorators = extractAttributes(from: withAttrs.attributes)
    }
    
    // Extract property wrappers from member declarations
    if let memberBlock = getMemberBlock(from: decl) {
      propertyWrappers = extractPropertyWrappers(from: memberBlock)
    }
    
    // Detect frameworks based on decorators and imports
    frameworks = detectFrameworksFromMetadata(decorators: decorators, protocols: protocols, imports: fileImports)
    
    // Extract type references (for orphan detection)
    let typeReferences = extractTypeReferences(from: decl)
    
    return ASTChunkMetadata(
      decorators: decorators,
      protocols: protocols,
      imports: [], // Only included in the imports chunk
      superclass: superclass,
      propertyWrappers: propertyWrappers,
      frameworks: frameworks,
      typeReferences: typeReferences
    )
  }
  
  /// Extract @attributes from a declaration
  private func extractAttributes(from attributes: AttributeListSyntax) -> [String] {
    var result: [String] = []
    
    for element in attributes {
      switch element {
      case .attribute(let attr):
        let name = attr.attributeName.trimmedDescription
        result.append("@\(name)")
      case .ifConfigDecl:
        // Skip #if blocks
        break
      }
    }
    
    return result
  }
  
  /// Extract superclass and protocols from inheritance clause
  private func extractInheritance(from clause: InheritanceClauseSyntax?) -> (superclass: String?, protocols: [String]) {
    guard let clause else { return (nil, []) }
    
    var superclass: String? = nil
    var protocols: [String] = []
    
    for (index, inherited) in clause.inheritedTypes.enumerated() {
      let typeName = inherited.type.trimmedDescription
      
      // First item could be superclass (for classes) - heuristic: starts with uppercase, not a known protocol
      if index == 0 && !isKnownProtocol(typeName) {
        // Could be superclass or protocol - we'll treat first as potential superclass for classes
        superclass = typeName
      } else {
        protocols.append(typeName)
      }
    }
    
    return (superclass, protocols)
  }
  
  /// Check if a type name is a known Swift protocol
  private func isKnownProtocol(_ name: String) -> Bool {
    let knownProtocols: Set<String> = [
      "View", "App", "Scene", "PreviewProvider",
      "Sendable", "Equatable", "Hashable", "Codable", "Identifiable",
      "Comparable", "CustomStringConvertible", "Error", "LocalizedError",
      "ObservableObject", "Publisher", "Subscriber",
      "Collection", "Sequence", "IteratorProtocol",
      "RawRepresentable", "CaseIterable", "OptionSet",
    ]
    return knownProtocols.contains(name)
  }
  
  /// Extract property wrappers from member variables
  private func extractPropertyWrappers(from memberBlock: MemberBlockSyntax) -> [String] {
    var wrappers: Set<String> = []
    
    for member in memberBlock.members {
      if let varDecl = member.decl.as(VariableDeclSyntax.self) {
        for element in varDecl.attributes {
          if case .attribute(let attr) = element {
            let name = attr.attributeName.trimmedDescription
            // Common property wrappers
            let propertyWrapperNames: Set<String> = [
              "State", "Binding", "ObservedObject", "StateObject", "EnvironmentObject",
              "Environment", "AppStorage", "SceneStorage", "FetchRequest", "Query",
              "Published", "Bindable", "Observable",
              "tracked", "service", "action", // Ember decorators
            ]
            if propertyWrapperNames.contains(name) {
              wrappers.insert("@\(name)")
            }
          }
        }
      }
    }
    
    return Array(wrappers).sorted()
  }
  
  /// Detect frameworks from decorators and protocols
  private func detectFrameworksFromMetadata(decorators: [String], protocols: [String], imports: [String]) -> [String] {
    var frameworks: Set<String> = []
    
    // SwiftUI indicators
    let swiftUIIndicators: Set<String> = ["@State", "@Binding", "@ObservedObject", "@StateObject", "@EnvironmentObject", "@Environment", "@AppStorage", "@Query"]
    let swiftUIProtocols: Set<String> = ["View", "App", "Scene", "PreviewProvider"]
    
    if !decorators.filter({ swiftUIIndicators.contains($0) }).isEmpty ||
       !protocols.filter({ swiftUIProtocols.contains($0) }).isEmpty ||
       imports.contains("SwiftUI") {
      frameworks.insert("SwiftUI")
    }
    
    // Observation framework
    if decorators.contains("@Observable") || decorators.contains("@Bindable") || imports.contains("Observation") {
      frameworks.insert("Observation")
    }
    
    // Combine
    if decorators.contains("@Published") || imports.contains("Combine") {
      frameworks.insert("Combine")
    }
    
    // SwiftData
    if decorators.contains("@Model") || imports.contains("SwiftData") {
      frameworks.insert("SwiftData")
    }
    
    // Concurrency
    if decorators.contains("@MainActor") || decorators.contains("@globalActor") {
      frameworks.insert("Concurrency")
    }
    
    return Array(frameworks).sorted()
  }
  
  private func extractTypeAndName(from decl: any DeclSyntaxProtocol) -> (ASTChunk.ConstructType, String?) {
    switch decl {
    case let classDecl as ClassDeclSyntax:
      return (.classDecl, classDecl.name.text)
    case let structDecl as StructDeclSyntax:
      return (.structDecl, structDecl.name.text)
    case let enumDecl as EnumDeclSyntax:
      return (.enumDecl, enumDecl.name.text)
    case let protocolDecl as ProtocolDeclSyntax:
      return (.protocolDecl, protocolDecl.name.text)
    case let extensionDecl as ExtensionDeclSyntax:
      let typeName = extensionDecl.extendedType.trimmedDescription
      return (.extension, "extension \(typeName)")
    case let actorDecl as ActorDeclSyntax:
      return (.actorDecl, actorDecl.name.text)
    case let funcDecl as FunctionDeclSyntax:
      return (.function, funcDecl.name.text)
    case let initDecl as InitializerDeclSyntax:
      // Check for failable init
      let failable = initDecl.optionalMark != nil ? "?" : ""
      return (.method, "init\(failable)")
    case let deinitDecl as DeinitializerDeclSyntax:
      _ = deinitDecl
      return (.method, "deinit")
    case let subscriptDecl as SubscriptDeclSyntax:
      _ = subscriptDecl
      return (.method, "subscript")
    default:
      return (.unknown, nil)
    }
  }
  
  // MARK: - Large Declaration Splitting
  
  private func splitLargeDeclaration(
    _ decl: any DeclSyntaxProtocol,
    constructType: ASTChunk.ConstructType,
    constructName: String?,
    lineMap: LineMap,
    maxChunkLines: Int,
    chunks: inout [ASTChunk],
    metadata: ASTChunkMetadata
  ) {
    // Get member block if this is a type with members
    guard let memberBlock = getMemberBlock(from: decl) else {
      // No member block - just split by lines
      let startLine = lineMap.line(for: decl.position)
      let endLine = lineMap.line(for: decl.endPosition)
      chunks.append(contentsOf: splitByLines(
        startLine: startLine,
        endLine: endLine,
        lineMap: lineMap,
        maxChunkLines: maxChunkLines,
        constructType: constructType,
        constructName: constructName,
        metadata: metadata
      ))
      return
    }
    
    // Collect methods and their boundaries
    var memberBoundaries: [(start: Int, end: Int, name: String, type: ASTChunk.ConstructType)] = []
    
    for member in memberBlock.members {
      if let funcDecl = member.decl.as(FunctionDeclSyntax.self) {
        let start = lineMap.line(for: funcDecl.positionAfterSkippingLeadingTrivia)
        let end = lineMap.line(for: funcDecl.endPositionBeforeTrailingTrivia)
        memberBoundaries.append((start, end, funcDecl.name.text, .method))
      } else if let initDecl = member.decl.as(InitializerDeclSyntax.self) {
        let start = lineMap.line(for: initDecl.positionAfterSkippingLeadingTrivia)
        let end = lineMap.line(for: initDecl.endPositionBeforeTrailingTrivia)
        let failable = initDecl.optionalMark != nil ? "?" : ""
        memberBoundaries.append((start, end, "init\(failable)", .method))
      } else if let subscriptDecl = member.decl.as(SubscriptDeclSyntax.self) {
        let start = lineMap.line(for: subscriptDecl.positionAfterSkippingLeadingTrivia)
        let end = lineMap.line(for: subscriptDecl.endPositionBeforeTrailingTrivia)
        memberBoundaries.append((start, end, "subscript", .method))
      } else if let deinitDecl = member.decl.as(DeinitializerDeclSyntax.self) {
        let start = lineMap.line(for: deinitDecl.positionAfterSkippingLeadingTrivia)
        let end = lineMap.line(for: deinitDecl.endPositionBeforeTrailingTrivia)
        memberBoundaries.append((start, end, "deinit", .method))
      }
    }
    
    memberBoundaries.sort { $0.start < $1.start }
    
    let declStart = lineMap.line(for: decl.positionAfterSkippingLeadingTrivia)
    let declEnd = lineMap.line(for: decl.endPositionBeforeTrailingTrivia)
    
    if memberBoundaries.isEmpty {
      // No methods to split on
      chunks.append(contentsOf: splitByLines(
        startLine: declStart,
        endLine: declEnd,
        lineMap: lineMap,
        maxChunkLines: maxChunkLines,
        constructType: constructType,
        constructName: constructName,
        metadata: metadata
      ))
      return
    }
    
    var currentStart = declStart
    
    for (memberStart, memberEnd, memberName, memberType) in memberBoundaries {
      // Header/properties before this method
      if memberStart > currentStart + 1 {
        let headerEnd = memberStart - 1
        let headerLineCount = headerEnd - currentStart + 1
        
        if headerLineCount >= 3 { // Only if substantial
          let text = lineMap.text(from: currentStart, to: headerEnd)
          chunks.append(ASTChunk(
            constructType: constructType,
            constructName: constructName,
            startLine: currentStart,
            endLine: headerEnd,
            text: text,
            language: Self.language,
            metadata: metadata
          ))
        }
      }
      
      // The method itself
      let methodLineCount = memberEnd - memberStart + 1
      let fullMemberName = combineName(parent: constructName, child: memberName)
      
      if methodLineCount <= maxChunkLines {
        let text = lineMap.text(from: memberStart, to: memberEnd)
        chunks.append(ASTChunk(
          constructType: memberType,
          constructName: fullMemberName,
          startLine: memberStart,
          endLine: memberEnd,
          text: text,
          language: Self.language,
          metadata: metadata  // Inherit parent metadata
        ))
      } else {
        // Very large method - split by lines
        chunks.append(contentsOf: splitByLines(
          startLine: memberStart,
          endLine: memberEnd,
          lineMap: lineMap,
          maxChunkLines: maxChunkLines,
          constructType: memberType,
          constructName: fullMemberName,
          metadata: metadata
        ))
      }
      
      currentStart = memberEnd + 1
    }
    
    // Trailing content (closing brace, etc.)
    if currentStart < declEnd {
      let text = lineMap.text(from: currentStart, to: declEnd)
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      // Only add if more than just closing brace
      if trimmed.count > 1 {
        chunks.append(ASTChunk(
          constructType: constructType,
          constructName: constructName,
          startLine: currentStart,
          endLine: declEnd,
          text: text,
          language: Self.language,
          metadata: metadata
        ))
      }
    }
  }
  
  private func getMemberBlock(from decl: any DeclSyntaxProtocol) -> MemberBlockSyntax? {
    switch decl {
    case let classDecl as ClassDeclSyntax:
      return classDecl.memberBlock
    case let structDecl as StructDeclSyntax:
      return structDecl.memberBlock
    case let enumDecl as EnumDeclSyntax:
      return enumDecl.memberBlock
    case let extensionDecl as ExtensionDeclSyntax:
      return extensionDecl.memberBlock
    case let actorDecl as ActorDeclSyntax:
      return actorDecl.memberBlock
    case let protocolDecl as ProtocolDeclSyntax:
      return protocolDecl.memberBlock
    default:
      return nil
    }
  }
  
  // MARK: - Helpers
  
  private func combineName(parent: String?, child: String?) -> String? {
    switch (parent, child) {
    case let (p?, c?):
      return "\(p).\(c)"
    case let (p?, nil):
      return p
    case let (nil, c?):
      return c
    case (nil, nil):
      return nil
    }
  }
  
  private func splitByLines(
    startLine: Int,
    endLine: Int,
    lineMap: LineMap,
    maxChunkLines: Int,
    constructType: ASTChunk.ConstructType,
    constructName: String?,
    metadata: ASTChunkMetadata = ASTChunkMetadata()
  ) -> [ASTChunk] {
    var chunks: [ASTChunk] = []
    var current = startLine
    
    while current <= endLine {
      let chunkEnd = min(current + maxChunkLines - 1, endLine)
      let text = lineMap.text(from: current, to: chunkEnd)
      
      chunks.append(ASTChunk(
        constructType: constructType,
        constructName: constructName,
        startLine: current,
        endLine: chunkEnd,
        text: text,
        language: Self.language,
        metadata: metadata
      ))
      
      current = chunkEnd + 1
    }
    
    return chunks
  }
  
  private func fallbackChunks(source: String, lineMap: LineMap, maxChunkLines: Int) -> [ASTChunk] {
    let totalLines = lineMap.lineCount
    return splitByLines(
      startLine: 1,
      endLine: totalLines,
      lineMap: lineMap,
      maxChunkLines: maxChunkLines,
      constructType: .file,
      constructName: nil,
      metadata: ASTChunkMetadata()
    )
  }
  
  // MARK: - Type Reference Extraction
  
  /// Extract type names referenced in a declaration (for orphan detection)
  /// This finds types used in:
  /// - Variable/property type annotations: `let x: SomeType`
  /// - Function parameters: `func foo(x: SomeType)`
  /// - Function return types: `func foo() -> SomeType`
  /// - Initializer calls: `SomeType()`
  /// - Static member access: `SomeType.property`
  func extractTypeReferences(from decl: any DeclSyntaxProtocol) -> [String] {
    let collector = TypeReferenceCollector(viewMode: .sourceAccurate)
    collector.walk(decl)
    return Array(collector.typeReferences).sorted()
  }
  
  /// Extract type references from a source file (for file-level tracking)
  func extractTypeReferences(from source: String) -> [String] {
    let sourceFile = Parser.parse(source: source)
    let collector = TypeReferenceCollector(viewMode: .sourceAccurate)
    collector.walk(sourceFile)
    return Array(collector.typeReferences).sorted()
  }
}

// MARK: - Type Reference Collector

/// SwiftSyntax visitor that collects type names referenced in code
private final class TypeReferenceCollector: SyntaxVisitor {
  var typeReferences: Set<String> = []
  
  // Skip built-in types
  private static let builtinTypes: Set<String> = [
    "String", "Int", "Double", "Float", "Bool", "Void",
    "Int8", "Int16", "Int32", "Int64",
    "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    "Character", "Data", "Date", "URL", "UUID",
    "Array", "Dictionary", "Set", "Optional",
    "Result", "Error", "Any", "AnyObject", "Self",
    "Never", "some"
  ]
  
  // MARK: - Type Annotations
  
  /// Visit type annotations (e.g., `let x: SomeType`)
  override func visit(_ node: TypeAnnotationSyntax) -> SyntaxVisitorContinueKind {
    extractTypeName(from: node.type)
    return .visitChildren
  }
  
  /// Visit function return types
  override func visit(_ node: ReturnClauseSyntax) -> SyntaxVisitorContinueKind {
    extractTypeName(from: node.type)
    return .visitChildren
  }
  
  /// Visit generic arguments (e.g., `Array<SomeType>`)
  override func visit(_ node: GenericArgumentClauseSyntax) -> SyntaxVisitorContinueKind {
    for argument in node.arguments {
      extractTypeName(from: argument.argument)
    }
    return .visitChildren
  }
  
  // MARK: - Function Calls (Initializers)
  
  /// Visit function calls - captures `SomeType()` initializer calls
  override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    // Check if callee is a simple identifier (type initializer)
    if let declRef = node.calledExpression.as(DeclReferenceExprSyntax.self) {
      let name = declRef.baseName.text
      if isUserType(name) {
        typeReferences.insert(name)
      }
    }
    // Check for member access like Module.Type()
    else if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) {
      // The last component is the type being instantiated
      let name = memberAccess.declName.baseName.text
      if isUserType(name) {
        typeReferences.insert(name)
      }
    }
    return .visitChildren
  }
  
  // MARK: - Static Member Access
  
  /// Visit member access expressions - captures `SomeType.staticMember`
  override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
    // Check if base is a type reference (static access)
    if let base = node.base?.as(DeclReferenceExprSyntax.self) {
      let name = base.baseName.text
      // Only capture if it looks like a type (starts with uppercase)
      if isUserType(name) && name.first?.isUppercase == true {
        typeReferences.insert(name)
      }
    }
    return .visitChildren
  }
  
  // MARK: - Inheritance
  
  /// Visit inheritance clauses (already captured in protocols, but add here too)
  override func visit(_ node: InheritanceClauseSyntax) -> SyntaxVisitorContinueKind {
    for inherited in node.inheritedTypes {
      extractTypeName(from: inherited.type)
    }
    return .visitChildren
  }
  
  // MARK: - Type Extraction Helpers
  
  private func extractTypeName(from type: TypeSyntax) {
    // Handle different type syntax forms
    if let identifierType = type.as(IdentifierTypeSyntax.self) {
      let name = identifierType.name.text
      if isUserType(name) {
        typeReferences.insert(name)
      }
    }
    else if let optionalType = type.as(OptionalTypeSyntax.self) {
      extractTypeName(from: optionalType.wrappedType)
    }
    else if let arrayType = type.as(ArrayTypeSyntax.self) {
      extractTypeName(from: arrayType.element)
    }
    else if let dictType = type.as(DictionaryTypeSyntax.self) {
      extractTypeName(from: dictType.key)
      extractTypeName(from: dictType.value)
    }
    else if let tupleType = type.as(TupleTypeSyntax.self) {
      for element in tupleType.elements {
        extractTypeName(from: element.type)
      }
    }
    else if let functionType = type.as(FunctionTypeSyntax.self) {
      for param in functionType.parameters {
        extractTypeName(from: param.type)
      }
      extractTypeName(from: functionType.returnClause.type)
    }
    else if let memberType = type.as(MemberTypeSyntax.self) {
      // Nested type like Module.Type - extract the innermost name
      let name = memberType.name.text
      if isUserType(name) {
        typeReferences.insert(name)
      }
    }
    else if let implicitUnwrapped = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
      extractTypeName(from: implicitUnwrapped.wrappedType)
    }
    else if let someOrAny = type.as(SomeOrAnyTypeSyntax.self) {
      extractTypeName(from: someOrAny.constraint)
    }
  }
  
  private func isUserType(_ name: String) -> Bool {
    !Self.builtinTypes.contains(name)
  }
}

// MARK: - LineMap Helper

/// Helper to convert between byte offsets and line numbers
private struct LineMap {
  private let lines: [String]
  private let lineStartOffsets: [Int]
  
  var lineCount: Int { lines.count }
  
  init(source: String) {
    self.lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    
    var offsets: [Int] = [0]
    var currentOffset = 0
    for line in lines {
      currentOffset += line.utf8.count + 1 // +1 for newline
      offsets.append(currentOffset)
    }
    self.lineStartOffsets = offsets
  }
  
  /// Convert AbsolutePosition to 1-indexed line number
  func line(for position: AbsolutePosition) -> Int {
    let offset = position.utf8Offset
    
    // Binary search for the line
    var low = 0
    var high = lineStartOffsets.count - 1
    
    while low < high {
      let mid = (low + high + 1) / 2
      if lineStartOffsets[mid] <= offset {
        low = mid
      } else {
        high = mid - 1
      }
    }
    
    return low + 1 // Convert to 1-indexed
  }
  
  /// Get text for a line range (1-indexed, inclusive)
  func text(from startLine: Int, to endLine: Int) -> String {
    let start = max(0, startLine - 1)
    let end = min(lines.count, endLine)
    guard start < end else { return "" }
    return lines[start..<end].joined(separator: "\n")
  }
}
