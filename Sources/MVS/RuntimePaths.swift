import Foundation

enum RuntimePaths {
    private static var isPackagedApp: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    static var roots: [URL] {
        var values: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            values.append(resourceURL)
        }
        if let executableURL = Bundle.main.executableURL {
            values.append(executableURL.deletingLastPathComponent())
        }
        if !isPackagedApp {
            values.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
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
        var candidates: [String?] = []
        if !isPackagedApp {
            candidates.append(ProcessInfo.processInfo.environment["MVS_PYTHON"])
        }
        candidates += [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        let resolved = candidates.compactMap { $0 }
        return resolved.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }
}
