# ASTChunker

AST-aware code chunking for RAG (Retrieval-Augmented Generation) systems. Extracts semantic chunks from source code using proper syntax parsing rather than naive line-based splitting.

## Features

- **Swift** - Full SwiftSyntax-based parsing with property wrapper, protocol, and decorator extraction
- **TypeScript/JavaScript** - AST chunking with Ember/Glimmer support
- **Ruby** - Parser-based chunking with Rails-aware metadata (associations, callbacks, mixins)
- **Glimmer** - Ember template tag (`<template>`) extraction

## Why AST Chunking?

Traditional RAG systems split code by lines or characters, breaking semantic boundaries:

```swift
// Bad: Line-based chunking might split here
func processData(_ input: Data) -> Result<Output,  // ← chunk boundary
    Error> {                                        // ← broken!
    // implementation
}
```

ASTChunker extracts complete semantic units:

```swift
// Good: Full function as one chunk with metadata
ASTChunk(
  kind: .function,
  name: "processData",
  content: "func processData(_ input: Data) -> Result<Output, Error> { ... }",
  metadata: ASTChunkMetadata(decorators: ["@MainActor"], ...)
)
```

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/crunchybananas/ast-chunker", from: "1.0.0")
]
```

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "ASTChunker", package: "ast-chunker")
    ]
)
```

## Usage

### Swift

```swift
import ASTChunker

let chunker = ASTChunkerService()

// Chunk a Swift file
let chunks = try await chunker.chunkFile(at: "/path/to/File.swift")

for chunk in chunks {
    print("\(chunk.kind): \(chunk.name ?? "anonymous")")
    print("  Lines: \(chunk.startLine)-\(chunk.endLine)")
    print("  Decorators: \(chunk.metadata.decorators)")
    print("  Protocols: \(chunk.metadata.protocols)")
}
```

### CLI

```bash
# Build the CLI
swift build -c release

# Chunk a file
.build/release/ast-chunker-cli /path/to/file.swift

# Output as JSON
.build/release/ast-chunker-cli --json /path/to/file.swift
```

## Chunk Types

| Kind | Description |
|------|-------------|
| `.class` | Class definitions |
| `.struct` | Struct definitions |
| `.enum` | Enum definitions |
| `.function` | Top-level functions |
| `.method` | Methods within types |
| `.property` | Property declarations |
| `.extension` | Swift extensions |
| `.protocol` | Protocol definitions |
| `.import` | Import statements (grouped) |
| `.module` | Ruby modules |
| `.template` | Glimmer template blocks |

## Metadata Extraction

ASTChunker extracts rich metadata for improved search relevance:

### Swift
- Property wrappers (`@State`, `@Environment`, `@Observable`)
- Protocol conformances
- Decorators/attributes (`@MainActor`, `@discardableResult`)
- Superclass inheritance
- Type references (for dependency tracking)

### Ruby
- Mixins (`include`, `extend`, `prepend`)
- ActiveRecord associations (`has_many`, `belongs_to`)
- Callbacks (`before_action`, `after_create`)
- Framework detection (Rails, RSpec)

### TypeScript/Glimmer
- Ember-concurrency usage detection
- Template tag extraction
- Framework-specific imports

## Supported Languages

| Language | Parser | Status |
|----------|--------|--------|
| Swift | SwiftSyntax 600 | ✅ Full support |
| TypeScript | Tree-sitter | ✅ Full support |
| JavaScript | Tree-sitter | ✅ Full support |
| Ruby | Parser gem | ✅ Full support |
| Glimmer/gts/gjs | Tree-sitter | ✅ Template extraction |

## Configuration

### Glimmer/GTS Support

Glimmer TypeScript (`.gts`/`.gjs`) parsing requires the tree-sitter CLI and a Glimmer grammar. Configure via environment variables or pass paths directly:

```bash
# Environment variables
export AST_CHUNKER_TREE_SITTER_CLI="/opt/homebrew/bin/tree-sitter"
export AST_CHUNKER_GLIMMER_LIB="/path/to/glimmer_typescript.dylib"
```

```swift
// Or pass paths directly
let chunker = GlimmerChunker(
    treeSitterLibPath: "/path/to/glimmer_typescript.dylib",
    treeSitterCLIPath: "/opt/homebrew/bin/tree-sitter"
)
```

**Installing tree-sitter CLI:**
```bash
# macOS (Homebrew)
brew install tree-sitter

# Or build from source
cargo install tree-sitter-cli
```

**Building Glimmer grammar:**
```bash
git clone https://github.com/ember-tooling/tree-sitter-glimmer-typescript
cd tree-sitter-glimmer-typescript
tree-sitter generate
# The .dylib will be in the build directory
```

The tree-sitter CLI is auto-detected in common paths (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`). The Glimmer library must be explicitly configured.

If Glimmer tools aren't available, the chunker falls back to line-based chunking automatically.

## Requirements

- macOS 15+ / iOS 18+
- Swift 6.0+

## License

MIT License - See [LICENSE](LICENSE) for details.

## Author

**Cory Loken** / [Crunchy Bananas](https://crunchybananas.com)

---

Built for [Peel](https://github.com/cloke/peel) - an AI-powered development environment.
