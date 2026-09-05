import Foundation

enum ArtifactTransaction {
    static func write(_ files: [(URL, Data)], directory: URL) throws {
        let manager = FileManager.default
        guard files.allSatisfy({ MVSPaths.isURL($0.0, inside: directory) }) else {
            throw MVSError.processFailed("Artifact destination is outside the project folder.")
        }
        let staging = directory.appendingPathComponent(".mvs-write-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var preserveStaging = false
        defer { if !preserveStaging { try? manager.removeItem(at: staging) } }
        var backups: [(URL, URL)] = []
        var written: [URL] = []
        do {
            for (index, file) in files.enumerated() {
                try file.1.write(to: staging.appendingPathComponent("new-\(index)"))
            }
            for (index, file) in files.enumerated() {
                let destination = file.0
                if manager.fileExists(atPath: destination.path) {
                    let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw MVSError.processFailed("Artifact is not a regular file: \(destination.lastPathComponent)")
                    }
                    let backup = staging.appendingPathComponent("old-\(index)")
                    try manager.moveItem(at: destination, to: backup)
                    backups.append((destination, backup))
                }
                try manager.moveItem(at: staging.appendingPathComponent("new-\(index)"), to: destination)
                written.append(destination)
            }
        } catch {
            for url in written.reversed() {
                do { try manager.removeItem(at: url) } catch { preserveStaging = true }
            }
            for (destination, backup) in backups.reversed() {
                do { try manager.moveItem(at: backup, to: destination) } catch { preserveStaging = true }
            }
            if preserveStaging {
                throw MVSError.processFailed("Artifact update failed. Recovery files were retained at \(staging.path).")
            }
            throw error
        }
    }
}
