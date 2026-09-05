import Foundation

// MVS writes a flat YAML header with JSON-quoted strings (valid YAML scalars).
struct NoteFrontMatter {
    private var lines: [String]
    private let closingIndex: Int?

    init(_ markdown: String) {
        let parsed = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        lines = parsed
        if lines.first == "---" {
            closingIndex = parsed.indices.dropFirst().first { parsed[$0] == "---" }
        } else {
            closingIndex = nil
        }
    }

    var body: String {
        guard let closingIndex else { return lines.joined(separator: "\n") }
        return lines.dropFirst(closingIndex + 1).joined(separator: "\n")
    }

    func value(_ key: String) -> String? {
        guard let closingIndex,
              let line = lines[1..<closingIndex].first(where: { $0.hasPrefix(key + ":") }) else { return nil }
        let raw = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("\"") {
            return try? JSONDecoder().decode(String.self, from: Data(raw.utf8))
        }
        if raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }

    func setting(_ key: String, to value: String) -> String {
        var updated = lines
        let replacement = "\(key): \(Self.quote(value))"
        if let closingIndex {
            if let index = (1..<closingIndex).first(where: { updated[$0].hasPrefix(key + ":") }) {
                updated[index] = replacement
            } else {
                updated.insert(replacement, at: closingIndex)
            }
        } else {
            updated = ["---", replacement, "---", ""] + updated
        }
        return updated.joined(separator: "\n")
    }

    static func quote(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

enum ProjectArtifacts {
    static let suffixes = ["md", "metadata.json", "transcript.srt", "transcript.md", "summary.json", "outline.md", "mindmap.md"]

    static func urls(for note: URL) -> [URL] {
        let base = note.deletingPathExtension()
        return suffixes.map { base.appendingPathExtension($0) }
    }
}
