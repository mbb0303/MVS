import Foundation

enum RuntimePaths {
    static var roots: [URL] {
        var values: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        ]
        if let resourceURL = Bundle.main.resourceURL {
            values.append(resourceURL)
        }
        if let executableURL = Bundle.main.executableURL {
            values.append(executableURL.deletingLastPathComponent())
        }

        var seen = Set<String>()
        return values.filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    static func toolCandidates(named name: String) -> [String] {
        roots.map { $0.appendingPathComponent(".tools/\(name)").path }
    }

    static func script(named name: String) -> URL? {
        roots
            .map { $0.appendingPathComponent("scripts/\(name)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func pythonPackagePath(named name: String) -> String? {
        roots
            .map { $0.appendingPathComponent(".tools/\(name)").path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    static func pythonExecutable() -> String {
        let candidates = [
            ProcessInfo.processInfo.environment["MVS_PYTHON"],
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }
}
