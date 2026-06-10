//
//  HandlebarsChunkerTests.swift
//  ASTChunkerTests
//
//  Pins the plain-.hbs chunker (cloke/peel#749): block-boundary chunking,
//  reference extraction (components/helpers/actions/partials, dasherized →
//  PascalCase normalization), unbalanced-template degradation, and service
//  dispatch.
//

import XCTest
@testable import ASTChunker

final class HandlebarsChunkerTests: XCTestCase {
  private let chunker = HandlebarsChunker()

  private let sampleTemplate = """
  <div class="profile">
    <UserAvatar @user={{this.user}} />
    {{format-date this.user.joinedAt}}
  </div>
  {{#if this.user.isAdmin}}
    {{component "admin-toolbar" user=this.user}}
    <button {{action "save"}}>Save</button>
  {{/if}}
  {{#each this.items as |item|}}
    {{> item/summary-row}}
    <Ui::Badge @label={{item.label}} />
  {{/each}}
  <footer>{{yield}}</footer>
  """

  func testLanguageIdentifier() {
    XCTAssertEqual(HandlebarsChunker.language, "handlebars")
  }

  func testFileExtensions() {
    XCTAssertTrue(HandlebarsChunker.handles(extension: "hbs"))
    XCTAssertTrue(HandlebarsChunker.handles(filename: "user-card.hbs"))
    XCTAssertFalse(HandlebarsChunker.handles(extension: "gts"))
    XCTAssertFalse(HandlebarsChunker.handles(extension: "swift"))
  }

  func testChunksAtTopLevelBlockBoundaries() {
    let chunks = chunker.chunk(source: sampleTemplate, maxChunkLines: 100)

    // Leading markup → template; {{#if}} and {{#each}} → blocks; trailing → template.
    XCTAssertEqual(chunks.map(\.constructType), [.template, .block, .block, .template])
    XCTAssertEqual(chunks[1].constructName, "if")
    XCTAssertEqual(chunks[2].constructName, "each")

    // 1-indexed, contiguous, covering the whole file.
    XCTAssertEqual(chunks.first?.startLine, 1)
    XCTAssertEqual(chunks.last?.endLine, sampleTemplate.components(separatedBy: "\n").count)
  }

  func testExtractsComponentHelperActionAndPartialReferences() {
    let chunks = chunker.chunk(source: sampleTemplate, maxChunkLines: 100)
    let allRefs = Set(chunks.flatMap(\.metadata.typeReferences))

    XCTAssertTrue(allRefs.contains("UserAvatar"), "angle-bracket component")
    XCTAssertTrue(allRefs.contains("admin-toolbar"), "string component literal")
    XCTAssertTrue(allRefs.contains("AdminToolbar"), "PascalCase normalization of dasherized name")
    XCTAssertTrue(allRefs.contains("save"), "action name")
    XCTAssertTrue(allRefs.contains("format-date"), "mustache helper head")
    XCTAssertTrue(allRefs.contains("item/summary-row"), "partial path")
    XCTAssertTrue(allRefs.contains("SummaryRow"), "PascalCase of partial leaf")
    XCTAssertTrue(allRefs.contains("Ui::Badge"), "namespaced component")
    XCTAssertTrue(allRefs.contains("Badge"), "last segment of namespaced component")

    // Paths, args, and builtins are NOT references.
    XCTAssertFalse(allRefs.contains("if"))
    XCTAssertFalse(allRefs.contains("each"))
    XCTAssertFalse(allRefs.contains("yield"))
    XCTAssertFalse(allRefs.contains { $0.contains("this.") })
  }

  func testUnbalancedTemplateDegradesToWholeFileChunk() {
    let unbalanced = """
    {{#if this.user}}
      <p>never closed</p>
    """
    let chunks = chunker.chunk(source: unbalanced, maxChunkLines: 100)
    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks[0].constructType, .template)
    XCTAssertEqual(chunks[0].startLine, 1)
  }

  func testSingleLineBlocksBalance() {
    let source = "{{#if a}}yes{{/if}}\n<p>{{name}}</p>"
    let chunks = chunker.chunk(source: source, maxChunkLines: 100)
    XCTAssertEqual(chunks.first?.constructType, .block)
    XCTAssertEqual(chunks.first?.constructName, "if")
  }

  func testLargeBlockSplitsProportionally() {
    let body = Array(repeating: "  <li>{{format-date this.d}}</li>", count: 120).joined(separator: "\n")
    let source = "{{#each this.items as |i|}}\n\(body)\n{{/each}}"
    let chunks = chunker.chunk(source: source, maxChunkLines: 50)

    XCTAssertGreaterThan(chunks.count, 1)
    XCTAssertTrue(chunks.allSatisfy { $0.lineCount <= 51 })
    XCTAssertTrue(chunks[0].constructName?.contains("part 1/") == true)
  }

  func testEmptySourceYieldsNoChunks() {
    XCTAssertTrue(chunker.chunk(source: "  \n \n", maxChunkLines: 100).isEmpty)
  }

  func testChunkLanguageMatchesCanonicalIdentifier() {
    let chunks = chunker.chunk(source: sampleTemplate, maxChunkLines: 100)
    XCTAssertTrue(chunks.allSatisfy { $0.language == HandlebarsChunker.language })
  }

  func testUnnamedSplitPartsStayUnnamedAndEmitNoDefinitions() {
    // A large nameless template chunk must not synthesize "template (part
    // 1/n)" names — those would become bogus component definition symbols.
    let body = Array(repeating: "<li>{{format-date this.d}}</li>", count: 120).joined(separator: "\n")
    let chunks = chunker.chunk(source: body, maxChunkLines: 50)

    XCTAssertGreaterThan(chunks.count, 1)
    XCTAssertTrue(chunks.allSatisfy { $0.constructName == nil })
    XCTAssertTrue(chunks.allSatisfy { $0.metadata.symbolDefinitions.isEmpty })
  }

  func testBareVariableLookupsAreNotReferences() {
    let source = """
    <p>{{name}} — {{email}}</p>
    <span>{{title}}</span>
    {{loading-spinner}}
    {{format-date this.joinedAt}}
    """
    let refs = Set(chunker.chunk(source: source, maxChunkLines: 100).flatMap(\.metadata.typeReferences))

    XCTAssertFalse(refs.contains("name"), "bare property lookup")
    XCTAssertFalse(refs.contains("email"), "bare property lookup")
    XCTAssertFalse(refs.contains("title"), "bare property lookup")
    XCTAssertTrue(refs.contains("loading-spinner"), "bare dasherized invocation is a helper/component")
    XCTAssertTrue(refs.contains("format-date"), "helper with arguments")
  }

  func testServiceDispatchesHbsFiles() {
    let service = ASTChunkerService()
    XCTAssertEqual(service.detectLanguage(for: "templates/user-card.hbs"), "handlebars")

    let chunks = service.chunk(source: sampleTemplate, filename: "user-card.hbs", maxChunkLines: 100)
    XCTAssertFalse(chunks.isEmpty)
    XCTAssertTrue(chunks.contains { $0.constructType == .block })
  }
}
