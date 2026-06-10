//
//  HandlebarsChunker.swift
//  ASTChunker
//
//  Chunker for plain Handlebars templates (.hbs) — classic Ember apps keep
//  templates separate from their JS/TS classes, so these files never reach
//  GlimmerChunker (cloke/peel#749). No handlebars tree-sitter grammar is
//  vendored (the Glimmer grammar lexes template bodies as raw text), so this
//  is a pure-Swift scanner: chunks split at depth-0 block-helper boundaries
//  ({{#each}}…{{/each}}), and component/helper/action invocations are
//  emitted as typeReferences so rag.references can answer "which templates
//  use X" — the issue's acceptance criterion.
//

import Foundation

/// Pure-Swift chunker for plain Handlebars templates. Always available —
/// no external grammar, CLI, or dylib required.
public struct HandlebarsChunker: LanguageChunker, Sendable {
  public static let language = "handlebars"
  public static let fileExtensions: Set<String> = ["hbs"]

  public init() {}

  public func chunk(source: String, maxChunkLines: Int) -> [ASTChunk] {
    let lines = source.components(separatedBy: "\n")
    guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

    guard let blocks = scanTopLevelBlocks(lines: lines) else {
      // Unbalanced block helpers (common in partial-heavy templates):
      // degrade to a single whole-file template chunk rather than guessing
      // at boundaries — references are still extracted from the full text.
      return [makeChunk(type: .template, name: nil, startLine: 0, endLine: lines.count - 1, lines: lines)]
        .flatMap { split($0, maxChunkLines: maxChunkLines, lines: lines) }
    }

    var constructs: [(type: ASTChunk.ConstructType, name: String?, start: Int, end: Int)] = []
    var cursor = 0
    for block in blocks {
      if block.start > cursor {
        appendTemplateGap(start: cursor, end: block.start - 1, lines: lines, into: &constructs)
      }
      constructs.append((type: .block, name: block.name, start: block.start, end: block.end))
      cursor = block.end + 1
    }
    if cursor < lines.count {
      appendTemplateGap(start: cursor, end: lines.count - 1, lines: lines, into: &constructs)
    }

    if constructs.isEmpty {
      constructs.append((type: .template, name: nil, start: 0, end: lines.count - 1))
    }

    return constructs.flatMap { construct -> [ASTChunk] in
      let chunk = makeChunk(
        type: construct.type, name: construct.name,
        startLine: construct.start, endLine: construct.end, lines: lines
      )
      return split(chunk, maxChunkLines: maxChunkLines, lines: lines)
    }
  }

  // MARK: - Block scanning

  private struct Block {
    let name: String
    let start: Int  // 0-indexed
    let end: Int    // 0-indexed
  }

  private static let openRegex = try? NSRegularExpression(pattern: #"\{\{[#^]([\w-]+)"#)
  private static let closeRegex = try? NSRegularExpression(pattern: #"\{\{/([\w-]+)\s*\}\}"#)

  /// Find depth-0 block-helper spans. Returns nil when opens/closes don't
  /// balance (the caller falls back to whole-file chunking).
  private func scanTopLevelBlocks(lines: [String]) -> [Block]? {
    guard let openRegex = Self.openRegex, let closeRegex = Self.closeRegex else { return nil }

    var blocks: [Block] = []
    var stack: [(name: String, line: Int)] = []

    for (lineIndex, line) in lines.enumerated() {
      let nsLine = line as NSString
      let range = NSRange(location: 0, length: nsLine.length)

      // Collect (position, isOpen, name) events in order of appearance so
      // single-line blocks like `{{#if x}}y{{/if}}` resolve correctly.
      var events: [(location: Int, isOpen: Bool, name: String)] = []
      for match in openRegex.matches(in: line, range: range) {
        events.append((match.range.location, true, nsLine.substring(with: match.range(at: 1))))
      }
      for match in closeRegex.matches(in: line, range: range) {
        events.append((match.range.location, false, nsLine.substring(with: match.range(at: 1))))
      }
      events.sort { $0.location < $1.location }

      for event in events {
        if event.isOpen {
          stack.append((event.name, lineIndex))
        } else {
          guard let open = stack.popLast(), open.name == event.name else { return nil }
          if stack.isEmpty {
            blocks.append(Block(name: open.name, start: open.line, end: lineIndex))
          }
        }
      }
    }

    return stack.isEmpty ? blocks : nil
  }

  private func appendTemplateGap(
    start: Int, end: Int, lines: [String],
    into constructs: inout [(type: ASTChunk.ConstructType, name: String?, start: Int, end: Int)]
  ) {
    let text = lines[start...end].joined(separator: "\n")
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    constructs.append((type: .template, name: nil, start: start, end: end))
  }

  // MARK: - Chunk assembly

  private func makeChunk(
    type: ASTChunk.ConstructType, name: String?,
    startLine: Int, endLine: Int, lines: [String]
  ) -> ASTChunk {
    let text = lines[startLine...endLine].joined(separator: "\n")
    return ASTChunk(
      constructType: type,
      constructName: name,
      startLine: startLine + 1,  // 1-indexed
      endLine: endLine + 1,
      text: text,
      language: Self.language,
      metadata: ASTChunkMetadata(typeReferences: Self.extractReferences(from: text))
    )
  }

  /// Proportional split for chunks exceeding maxChunkLines (mirrors
  /// NativeGlimmerParser.splitLargeConstruct's `(part i/n)` naming).
  private func split(_ chunk: ASTChunk, maxChunkLines: Int, lines: [String]) -> [ASTChunk] {
    guard chunk.lineCount > maxChunkLines else { return [chunk] }

    let start0 = chunk.startLine - 1
    let end0 = chunk.endLine - 1
    let totalLines = end0 - start0 + 1
    let numChunks = (totalLines + maxChunkLines - 1) / maxChunkLines
    let linesPerChunk = totalLines / numChunks

    return (0..<numChunks).map { i in
      let partStart = start0 + (i * linesPerChunk)
      let partEnd = i == numChunks - 1 ? end0 : min(start0 + ((i + 1) * linesPerChunk) - 1, end0)
      let text = lines[partStart...partEnd].joined(separator: "\n")
      // Nameless chunks stay nameless — synthesizing "template (part 1/3)"
      // would become a definition symbol via withNormalizedSymbols and
      // pollute rag.definitions with non-symbols.
      return ASTChunk(
        constructType: chunk.constructType,
        constructName: chunk.constructName.map { "\($0) (part \(i + 1)/\(numChunks))" },
        startLine: partStart + 1,
        endLine: partEnd + 1,
        text: text,
        language: Self.language,
        metadata: ASTChunkMetadata(typeReferences: Self.extractReferences(from: text))
      )
    }
  }

  // MARK: - Reference extraction

  /// Built-in helpers/keywords that would otherwise flood symbol_refs with
  /// noise (degrading orphan detection, which reads the same table).
  static let builtinHelpers: Set<String> = [
    "if", "else", "each", "unless", "let", "with", "yield", "outlet",
    "component", "action", "on", "fn", "concat", "hash", "array", "get",
    "mut", "log", "debugger", "unbound", "input", "textarea", "link-to",
    "query-params", "has-block", "has-block-params", "in-element", "t",
    "loc", "partial", "mount", "did-insert", "did-update", "will-destroy",
  ]

  private static let referencePatterns: [(pattern: String, group: Int)] = [
    // {{component "user-card"}} / {{#component "user-card"}}
    (#"\{\{#?component\s+"([\w/-]+)""#, 1),
    // {{action "save"}} / {{action 'save'}}
    (#"\{\{action\s+["']([\w-]+)["']"#, 1),
    // Angle-bracket component invocation: <UserAvatar ...> / <Ui::Button>
    (#"<([A-Z][\w:]*)[\s/>]"#, 1),
    // Partials: {{> user/avatar}}
    (#"\{\{>\s*([\w/-]+)"#, 1),
    // Mustache helper/component heads WITH arguments or block form:
    // {{format-date now}} / {{#power-select ...}}. Bare lookups like
    // {{name}} are property reads, not symbol references — requiring a
    // following space/paren (not `}`) keeps them out.
    (#"\{\{[#^]?([a-z][\w-]*)[\s(]"#, 1),
    // Bare dasherized invocations: {{loading-spinner}}. Ember properties
    // are camelCase; a dash in a bare mustache means helper/component.
    (#"\{\{([a-z]\w*(?:-[\w-]+)+)\s*\}\}"#, 1),
  ]

  /// Extract referenced component/helper/action/partial names. Dasherized
  /// names also emit their PascalCase form (user-card → UserCard) so
  /// rag.references on the component CLASS name finds template usages.
  static func extractReferences(from text: String) -> [String] {
    var refs = Set<String>()
    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)

    for (pattern, group) in referencePatterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      for match in regex.matches(in: text, range: fullRange) {
        guard match.numberOfRanges > group else { continue }
        let range = match.range(at: group)
        guard range.location != NSNotFound else { continue }
        let captured = nsText.substring(with: range)

        // Paths ({{this.foo}}), args ({{@name}}) and builtins are not refs.
        guard !captured.contains("."), !captured.contains("@"),
              !builtinHelpers.contains(captured) else { continue }

        refs.insert(captured)
        if let pascal = pascalCase(fromDasherized: captured) {
          refs.insert(pascal)
        }
        // Namespaced angle components: also emit the last segment
        // (Ui::Button → Button) so unqualified class names match.
        if captured.contains("::"), let last = captured.components(separatedBy: "::").last, !last.isEmpty {
          refs.insert(last)
        }
      }
    }

    return refs.sorted()
  }

  /// user-card → UserCard, user/avatar-image → AvatarImage. nil when the
  /// input has no dash/slash (already PascalCase or a single lowercase word
  /// whose capitalization would just duplicate noise).
  private static func pascalCase(fromDasherized name: String) -> String? {
    guard name.contains("-") || name.contains("/") else { return nil }
    let lastSegment = name.components(separatedBy: "/").last ?? name
    let parts = lastSegment.components(separatedBy: "-").filter { !$0.isEmpty }
    guard !parts.isEmpty else { return nil }
    return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
  }
}
