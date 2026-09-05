import Foundation

struct AnalysisCheckpoint: Codable {
    let jobID: UUID
    let source: VideoSourceKind
    let title: String
    let metadata: MediaMetadataArtifact
    let videoURL: URL?
    let duration: Double?
    let transcript: TranscriptResult
    let transcriptModel: String
    let sourceURL: String?
    let keepVideo: Bool

    static func url(jobID: UUID, vault: URL) -> URL {
        vault.appendingPathComponent(".mvs/checkpoints").appendingPathComponent(jobID.uuidString + ".json")
    }

    func save(vault: URL) throws {
        let url = Self.url(jobID: jobID, vault: vault)
        guard MVSPaths.isURL(url, inside: vault) else { throw MVSError.processFailed("Checkpoint folder is outside the library.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func load(jobID: UUID, vault: URL) throws -> Self? {
        let path = url(jobID: jobID, vault: vault)
        guard MVSPaths.isURL(path, inside: vault) else { throw MVSError.processFailed("Checkpoint is outside the library.") }
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
        guard value.jobID == jobID else { throw MVSError.processFailed("Checkpoint does not match this job.") }
        return value
    }
}
