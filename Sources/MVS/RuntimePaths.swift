import Foundation

enum RuntimePaths {
    static var resourceBundle: Bundle {
        if isPackagedApp {
            if let url = Bundle.main.resourceURL?.appendingPathComponent("MVS_MVS.bundle"),
               let bundle = Bundle(url: url) { return bundle }
            return Bundle.main
        }
        return Bundle.module
    }
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

    static func pythonExecutable() throws -> String {
        if let versionURL = roots.map({ $0.appendingPathComponent(".tools/python-version") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
           let raw = try? String(contentsOf: versionURL, encoding: .utf8) {
            let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard version.range(of: #"^3\.[0-9]+$"#, options: .regularExpression) != nil else {
                throw MVSError.processFailed("Invalid bundled Python version.")
            }
            let candidates = ["/opt/homebrew/bin/python\(version)", "/opt/homebrew/opt/python@\(version)/bin/python\(version)", "/usr/local/bin/python\(version)"]
            guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw MVSError.processFailed("MVS requires Python \(version). Install it with: brew install python@\(version)")
            }
            return python
        }
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
