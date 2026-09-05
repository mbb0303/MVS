import XCTest
@testable import MVS

final class JobRecoveryTests: XCTestCase {
    @MainActor
    func testCredentialLoadingIsDeferredAndShared() async throws {
        let suite = "mvs-credential-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let counter = LoadCounter()
        let settings = SettingsStore(defaults: defaults, credentialLoader: {
            counter.increment()
            Thread.sleep(forTimeInterval: 0.1)
            return ["summary.deepseek": "test-placeholder"]
        })
        XCTAssertEqual(counter.value, 0)
        async let first: Void = settings.prepareCredentials()
        async let second: Void = settings.prepareCredentials()
        _ = await (first, second)
        XCTAssertEqual(counter.value, 1)
        XCTAssertTrue(settings.hasDeepSeekAPIKey)
    }
    @MainActor
    func testCancellingJobRemainsActiveUntilCleanupCompletes() async throws {
        let jobs = JobStore()
        var job = AnalysisJob(source: .url, title: "Test")
        job.status = .running
        jobs.add(job)
        let task = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(20))
        }
        jobs.attach(task, to: job.id)
        jobs.cancel(job.id)
        XCTAssertTrue(jobs.hasActiveJobs)
        XCTAssertEqual(jobs.job(with: job.id)?.status, .running)
        jobs.clearHistory()
        XCTAssertEqual(jobs.jobs.count, 1)
        await task.value
        jobs.detachTask(for: job.id)
        XCTAssertFalse(jobs.hasActiveJobs)
        XCTAssertEqual(jobs.job(with: job.id)?.status, .cancelled)
    }

    @MainActor
    func testPersistedOptionsAndSourceSurviveRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mvs-job-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = TestLocations(vaultURL: root, videoRootURL: root.appendingPathComponent("assets"))
        let first = JobStore()
        first.configure(settings: locations)
        var job = AnalysisJob(source: .url, title: "Test")
        job.urlOptions = URLAnalysisOptions(keepDownloadedVideo: true, preferPlatformSubtitles: false, forceASR: true)
        job.sourceURL = "https://example.com/video"
        first.add(job)
        let second = JobStore()
        second.configure(settings: locations)
        let recovered = try XCTUnwrap(second.jobs.first)
        XCTAssertEqual(recovered.status, .failed)
        XCTAssertEqual(recovered.urlOptions, job.urlOptions)
        XCTAssertEqual(recovered.sourceURL, job.sourceURL)
    }
}

private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
