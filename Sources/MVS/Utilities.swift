import Foundation

enum MVSPaths {
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
}

struct ShellResult {
    let stdout: String
    let stderr: String
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let value = String(data: data, encoding: .utf8) ?? ""
        lock.unlock()
        return value
    }
}

private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""

    func append(_ text: String) -> [String] {
        lock.lock()
        pending += text
        let pieces = pending.components(separatedBy: .newlines)
        pending = pieces.last ?? ""
        let complete = Array(pieces.dropLast()).filter { !$0.isEmpty }
        lock.unlock()
        return complete
    }
}

enum ShellRunner {
    static func run(_ executable: String, _ arguments: [String]) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { process in
                let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: ShellResult(stdout: out, stderr: err))
                } else {
                    let message = err.isEmpty ? out : err
                    continuation.resume(throwing: MVSError.processFailed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    static func runStreaming(
        _ executable: String,
        _ arguments: [String],
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> ShellResult {
        try await runWithEnvironment(executable, arguments, environment: [:], onOutputLine: onOutputLine)
    }

    static func runWithEnvironment(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }

            let stdout = Pipe()
            let stderr = Pipe()
            let stdoutData = LockedData()
            let stderrData = LockedData()
            let stdoutLines = LineBuffer()
            let stderrLines = LineBuffer()

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stdoutData.append(data)
                guard let text = String(data: data, encoding: .utf8) else { return }
                stdoutLines.append(text).forEach(onOutputLine)
            }

            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stderrData.append(data)
                guard let text = String(data: data, encoding: .utf8) else { return }
                stderrLines.append(text).forEach(onOutputLine)
            }

            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = Pipe()

            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                let result = ShellResult(stdout: stdoutData.string(), stderr: stderrData.string())
                if process.terminationStatus == 0 {
                    continuation.resume(returning: result)
                } else {
                    let message = result.stderr.isEmpty ? result.stdout : result.stderr
                    continuation.resume(throwing: MVSError.processFailed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }

            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
