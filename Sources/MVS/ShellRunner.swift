import Foundation
import Darwin

struct ShellResult: Sendable {
    let stdout: String
    let stderr: String
}

private final class ProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var cancelled = false
    private var timedOut = false

    func attach(_ value: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        pid = value
        if cancelled || timedOut { kill(-value, SIGKILL) }
    }

    func stop(timeout: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        if timeout { timedOut = true } else { cancelled = true }
        if let pid { kill(-pid, SIGKILL) }
    }

    func finish() -> (cancelled: Bool, timedOut: Bool) {
        lock.lock()
        defer { lock.unlock() }
        pid = nil
        return (cancelled, timedOut)
    }
}

private final class ProcessOutput: @unchecked Sendable {
    private(set) var data = Data()
    private(set) var exceededLimit = false
    private let limit: Int
    private let keepTail: Bool

    init(limit: Int, keepTail: Bool = false) {
        self.limit = limit
        self.keepTail = keepTail
    }

    // Each stream has a single reader. Results are inspected only after the reader group finishes.
    func read(_ handle: FileHandle, onLine: @Sendable (String) -> Void) {
        defer { try? handle.close() }
        var pending = Data()
        while let bytes = try? handle.read(upToCount: 32 * 1024), !bytes.isEmpty {
            let remaining = max(0, limit - data.count)
            if bytes.count > remaining { exceededLimit = true }
            if keepTail {
                data.append(bytes)
                if data.count > limit { data.removeFirst(data.count - limit) }
            } else {
                data.append(bytes.prefix(remaining))
            }
            pending.append(bytes)
            while let index = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                if index > pending.startIndex {
                    onLine(String(decoding: pending[..<index], as: UTF8.self))
                }
                pending.removeSubrange(...index)
            }
            if pending.count > 64 * 1024 {
                pending.removeFirst(pending.count - 64 * 1024)
            }
        }
        if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
    }
}

enum ShellRunner {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 3600) async throws -> ShellResult {
        try await runWithEnvironment(executable, arguments, environment: [:], timeout: timeout) { _ in }
    }

    static func runStreaming(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 3600,
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> ShellResult {
        try await runWithEnvironment(executable, arguments, environment: [:], timeout: timeout, onOutputLine: onOutputLine)
    }

    static func runWithEnvironment(
        _ executable: String, _ arguments: [String], environment: [String: String],
        standardInput: Data? = nil, timeout: TimeInterval = 3600,
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> ShellResult {
        let state = ProcessState()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
                        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                        let allHandles = [stdout.fileHandleForReading, stdout.fileHandleForWriting,
                            stderr.fileHandleForReading, stderr.fileHandleForWriting,
                            stdin.fileHandleForReading, stdin.fileHandleForWriting]
                        defer { allHandles.forEach { try? $0.close() } }
                        var actions: posix_spawn_file_actions_t?
                        var attributes: posix_spawnattr_t?
                        posix_spawn_file_actions_init(&actions)
                        posix_spawnattr_init(&attributes)
                        defer {
                            posix_spawn_file_actions_destroy(&actions)
                            posix_spawnattr_destroy(&attributes)
                        }
                        posix_spawn_file_actions_adddup2(&actions, stdin.fileHandleForReading.fileDescriptor, STDIN_FILENO)
                        posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
                        posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
                        for handle in allHandles {
                            posix_spawn_file_actions_addclose(&actions, handle.fileDescriptor)
                        }
                        // Create the process group before exec; setpgid after Process.run races with exec.
                        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
                        posix_spawnattr_setpgroup(&attributes, 0)
                        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
                        let env = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
                        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
                        defer {
                            argv.forEach { free($0) }
                            envp.forEach { free($0) }
                        }
                        var pid: pid_t = 0
                        let code = argv.withUnsafeBufferPointer { args in
                            envp.withUnsafeBufferPointer { vars in
                                posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, vars.baseAddress!)
                            }
                        }
                        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
                        state.attach(pid)
                        try? stdin.fileHandleForReading.close()
                        try? stdout.fileHandleForWriting.close()
                        try? stderr.fileHandleForWriting.close()
                        let out = ProcessOutput(limit: 32 * 1024 * 1024)
                        let err = ProcessOutput(limit: 256 * 1024, keepTail: true)
                        let readers = DispatchGroup()
                        DispatchQueue.global().async(group: readers) { out.read(stdout.fileHandleForReading, onLine: onOutputLine) }
                        DispatchQueue.global().async(group: readers) { err.read(stderr.fileHandleForReading, onLine: onOutputLine) }
                        DispatchQueue.global().async(group: readers) {
                            if let standardInput { try? stdin.fileHandleForWriting.write(contentsOf: standardInput) }
                            try? stdin.fileHandleForWriting.close()
                        }
                        let timer = DispatchSource.makeTimerSource()
                        timer.schedule(deadline: .now() + max(0.1, timeout))
                        timer.setEventHandler { state.stop(timeout: true) }
                        timer.resume()
                        var info = siginfo_t()
                        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
                        // Keep the leader unreaped until the group is stopped, preventing PID reuse.
                        kill(-pid, SIGKILL)
                        let stopped = state.finish()
                        timer.cancel()
                        var status: Int32 = 0
                        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                        readers.wait()
                        if stopped.cancelled { throw CancellationError() }
                        if stopped.timedOut { throw MVSError.processFailed("Process timed out: \(URL(fileURLWithPath: executable).lastPathComponent)") }
                        let result = ShellResult(stdout: String(decoding: out.data, as: UTF8.self),
                            stderr: String(decoding: err.data, as: UTF8.self))
                        guard status == 0 else {
                            throw MVSError.processFailed(DiagnosticRedactor.redact(result.stderr.isEmpty ? result.stdout : result.stderr))
                        }
                        guard !out.exceededLimit else { throw MVSError.processFailed("Process output exceeded the 32 MB limit.") }
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            state.stop()
        }
    }
}
