import Foundation
import ASTChunker

/// Output chunk for JSON mode (subprocess protocol)
struct JSONChunk: Codable {
  let startLine: Int
  let endLine: Int
  let text: String
  let constructType: String
  let constructName: String?
  let tokenCount: Int
  let metadata: String?  // JSON-encoded ASTChunkMetadata
}

/// Simple CLI to test the AST chunker on real files
/// JSON mode is used for subprocess isolation (--json <file>)
@main
struct CLI {
  static func main() {
    let args = CommandLine.arguments

    // JSON mode for subprocess integration (issue #177)
    if args.count >= 3 && args[1] == "--json" {
      let filePath = args[2]
      processFileJSON(filePath)
      return
    }

    guard args.count >= 2 else {
      print("Usage: ast-chunker-cli <file.swift> [--verbose]")
      print("       ast-chunker-cli <directory> [--verbose]")
      print("       ast-chunker-cli --json <file.swift>  # For subprocess integration")
      return
    }

    let path = args[1]
    let verbose = args.contains("--verbose")
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false

    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
      print("Error: Path does not exist: \(path)")
      return
    }

    if isDirectory.boolValue {
      processDirectory(path, verbose: verbose)
    } else {
      processFile(path, verbose: verbose)
    }
  }

  static func processDirectory(_ directory: String, verbose: Bool) {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(atPath: directory) else {
      print("Error: Cannot enumerate directory")
      return
    }

    var totalChunks = 0
    var totalFiles = 0
    var stats: [ASTChunk.ConstructType: Int] = [:]

    while let relativePath = enumerator.nextObject() as? String {
      guard relativePath.hasSuffix(".swift") else { continue }
      let fullPath = (directory as NSString).appendingPathComponent(relativePath)

      guard let source = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }

      let chunker = SwiftChunker()
      let chunks = chunker.chunk(source: source)

      totalFiles += 1
      totalChunks += chunks.count

      for chunk in chunks {
        stats[chunk.constructType, default: 0] += 1
      }

      if verbose {
        print("\n\(relativePath): \(chunks.count) chunks")
        for chunk in chunks {
          let lineCount = chunk.endLine - chunk.startLine + 1
          print("  \(chunk.constructType): \(chunk.constructName ?? "unnamed") (lines \(chunk.startLine)-\(chunk.endLine), \(lineCount) lines)")
        }
      }
    }

    print("\n=== Summary ===")
    print("Files processed: \(totalFiles)")
    print("Total chunks: \(totalChunks)")
    print("\nBy type:")
    for (type, count) in stats.sorted(by: { $0.value > $1.value }) {
      print("  \(type): \(count)")
    }
  }

  static func processFile(_ path: String, verbose: Bool) {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
      print("Error: Cannot read file: \(path)")
      return
    }

    let filename = (path as NSString).lastPathComponent
    let chunker = SwiftChunker()
    let chunks = chunker.chunk(source: source)

    print("File: \(filename)")
    print("Total chunks: \(chunks.count)")
    print("---")

    for chunk in chunks {
      let lineCount = chunk.endLine - chunk.startLine + 1
      print("\(chunk.constructType): \(chunk.constructName ?? "unnamed") (lines \(chunk.startLine)-\(chunk.endLine), \(lineCount) lines)")

      if verbose {
        let preview = chunk.text.split(separator: "\n").prefix(3).joined(separator: "\n")
        print("  Preview: \(preview.prefix(80))...")
      }
    }
  }

  /// JSON output for subprocess integration (used by HybridChunker)
  static func processFileJSON(_ path: String) {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
      fputs("Error: Cannot read file: \(path)\n", stderr)
      exit(1)
    }

    let chunker = SwiftChunker()
    let chunks = chunker.chunk(source: source)

    if chunks.isEmpty {
      // Output empty array (parse error or empty file)
      print("[]")
      return
    }

    let output = chunks.map { chunk in
      JSONChunk(
        startLine: chunk.startLine,
        endLine: chunk.endLine,
        text: chunk.text,
        constructType: chunk.constructType.rawValue,
        constructName: chunk.constructName,
        tokenCount: chunk.estimatedTokenCount,
        metadata: chunk.metadata.toJSON()
      )
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]  // Consistent output, no pretty print for speed
    do {
      let data = try encoder.encode(output)
      if let json = String(data: data, encoding: .utf8) {
        print(json)
      } else {
        fputs("Error: Failed to encode JSON\n", stderr)
        exit(1)
      }
    } catch {
      fputs("Error: JSON encoding failed: \(error)\n", stderr)
      exit(1)
    }
  }
}
