import Foundation
import SwiftUI
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@MainActor
final class JobStore: ObservableObject {
    @Published private(set) var jobs: [AnalysisJob] = []
    private var persistence: JobPersistence?

    func configure(settings: SettingsStore) {
        do {
            let database = try JobPersistence(vaultURL: settings.vaultURL)
            persistence = database
            var loaded = try database.loadJobs()
            for index in loaded.indices where loaded[index].status == .running || loaded[index].status == .queued {
                loaded[index].status = .failed
                loaded[index].stage = .failed
                loaded[index].progress = "Interrupted before completion"
                loaded[index].errorMessage = "MVS was closed before this task finished. Use Retry to run it again from the original URL or archived video."
                loaded[index].canRetry = true
                loaded[index].updatedAt = Date()
                try? database.save(loaded[index])
            }
            jobs = loaded
                .filter { $0.status != .completed || Calendar.current.dateComponents([.day], from: $0.updatedAt, to: Date()).day ?? 0 < 7 }
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            jobs = jobs
        }
    }

    func add(_ job: AnalysisJob) {
        var job = job
        job.updatedAt = Date()
        jobs.insert(job, at: 0)
        try? persistence?.save(job)
    }

    func update(_ id: AnalysisJob.ID, _ mutate: (inout AnalysisJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
        jobs[index].updatedAt = Date()
        try? persistence?.save(jobs[index])
    }

    func cancel(_ id: AnalysisJob.ID) {
        update(id) {
            guard $0.status == .queued || $0.status == .running else { return }
            $0.status = .cancelled
            $0.stage = .failed
            $0.progress = "Cancelled"
            $0.canRetry = true
        }
    }

    func job(with id: AnalysisJob.ID) -> AnalysisJob? {
        jobs.first { $0.id == id }
    }

    func remove(_ id: AnalysisJob.ID) {
        jobs.removeAll { $0.id == id }
        try? persistence?.delete(id)
    }
}

private final class JobPersistence {
    private let dbURL: URL
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(vaultURL: URL) throws {
        let directory = vaultURL.appendingPathComponent(".mvs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbURL = directory.appendingPathComponent("jobs.sqlite")
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            throw MVSError.processFailed("Could not open jobs database at \(dbURL.path).")
        }
        try execute("""
        CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY NOT NULL,
            json TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        """)
    }

    deinit {
        sqlite3_close(db)
    }

    func loadJobs() throws -> [AnalysisJob] {
        let sql = "SELECT json FROM jobs ORDER BY updated_at DESC;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }

        var jobs: [AnalysisJob] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let json = String(cString: raw)
            guard let data = json.data(using: .utf8),
                  let job = try? decoder.decode(AnalysisJob.self, from: data) else { continue }
            jobs.append(job)
        }
        return jobs
    }

    func save(_ job: AnalysisJob) throws {
        let data = try encoder.encode(job)
        guard let json = String(data: data, encoding: .utf8) else { return }
        let sql = "INSERT INTO jobs (id, json, updated_at) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json, updated_at = excluded.updated_at;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, job.id.uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, json, -1, sqliteTransient)
        sqlite3_bind_double(statement, 3, job.updatedAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
        }
    }

    func delete(_ id: AnalysisJob.ID) throws {
        let sql = "DELETE FROM jobs WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id.uuidString, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
        }
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "Unknown SQLite error."
            sqlite3_free(error)
            throw MVSError.processFailed(message)
        }
    }

    private func databaseError() -> Error {
        let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown SQLite error."
        return MVSError.processFailed(message)
    }
}
