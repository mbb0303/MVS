import Foundation
import Darwin
import CryptoKit

enum MVSPaths {
    static func artifactStem(_ mediaID: String) -> String {
        let hash = SHA256.hash(data: Data(mediaID.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return String(sanitizeFilename(mediaID).prefix(65)) + "-" + hash
    }

    static func keyword(_ value: String) -> String {
        String(value.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" ? Character($0) : "-"
        }).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    static let legacyObsidianVaultPath = "/Users/mbb/Library/Mobile Documents/iCloud~md~obsidian/Documents/Application/MVS"

    static var defaultLibraryPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MVS/Library", isDirectory: true).path
    }

    static var defaultVaultPath: String { defaultLibraryPath }

    static func shouldMoveLegacyDefaultPath(_ path: String?) -> Bool {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path == URL(fileURLWithPath: legacyObsidianVaultPath).standardizedFileURL.path
    }

    static func isInsideLegacyObsidianStorage(_ path: String?) -> Bool {
        guard let path else { return false }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let legacy = URL(fileURLWithPath: legacyObsidianVaultPath).standardizedFileURL.path
        return standardized == legacy || standardized.hasPrefix(legacy + "/")
    }

    static func sanitizeFilename(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ ")
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let compact = String(scalars)
            .replacingOccurrences(of: #"[\s\-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return compact.isEmpty ? "untitled" : String(compact.prefix(90))
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }

    static func yearMonth(_ date: Date = Date()) -> (String, String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy"
        let year = formatter.string(from: date)
        formatter.dateFormat = "MM"
        return (year, formatter.string(from: date))
    }

    static func relativePath(from baseFile: URL, to target: URL) -> String {
        let baseComponents = baseFile.deletingLastPathComponent().standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        var index = 0
        while index < baseComponents.count,
              index < targetComponents.count,
              baseComponents[index] == targetComponents[index] {
            index += 1
        }
        let up = Array(repeating: "..", count: baseComponents.count - index)
        let down = Array(targetComponents[index...])
        return (up + down).joined(separator: "/")
    }

    static func isURL(_ candidate: URL, inside directory: URL) -> Bool {
        let child = candidate.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard child.count >= parent.count else { return false }
        return child.prefix(parent.count).elementsEqual(parent)
    }
}
