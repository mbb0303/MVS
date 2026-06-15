import Foundation

@MainActor
final class BailianASRClient {
    private let apiKey: String
    private let model: String

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    func transcribe(chunks: [URL], progress: (@Sendable (String) -> Void)? = nil) async throws -> TranscriptResult {
        guard let script = RuntimePaths.script(named: "transcribe-bailian-asr.py") else {
            throw MVSError.processFailed("Missing Bailian ASR script. Run scripts/build-app.sh again or start MVS from the project directory.")
        }

        let result = try await ShellRunner.runWithEnvironment(
            RuntimePaths.pythonExecutable(),
            [script.path, "--model", model] + chunks.map(\.path),
            environment: [
                "DASHSCOPE_API_KEY": apiKey,
                "PYTHONPATH": dashscopePythonPath()
            ]
        ) { line in
            if line.hasPrefix("PROGRESS ") {
                progress?(String(line.dropFirst("PROGRESS ".count)))
            }
        }

        guard let data = result.stdout.data(using: .utf8) else {
            throw MVSError.processFailed("Bailian ASR output was not UTF-8.")
        }
        do {
            return try JSONDecoder().decode(TranscriptResult.self, from: data)
        } catch {
            let preview = result.stdout.prefix(1000)
            throw MVSError.processFailed("Bailian ASR transcript JSON could not be decoded: \(error.localizedDescription). Output: \(preview)")
        }
    }

    private func dashscopePythonPath() -> String {
        let bundled = RuntimePaths.pythonPackagePath(named: "dashscope-pkg") ?? ""
        let current = ProcessInfo.processInfo.environment["PYTHONPATH"]
        if bundled.isEmpty {
            return current ?? ""
        }
        if let current, !current.isEmpty {
            return "\(bundled):\(current)"
        }
        return bundled
    }
}
