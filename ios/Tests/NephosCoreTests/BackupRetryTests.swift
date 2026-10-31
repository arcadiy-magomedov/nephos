import Foundation
import XCTest

@testable import NephosCore

final class BackupRetryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let library = UUID()

    private func record() -> UploadRecord {
        UploadRecord(
            id: UUID(), libraryId: library, fileName: "photo.jpg", mediaType: "image/jpeg",
            size: 100, sha256: String(repeating: "a", count: 64),
            source: SourceRevision(
                localIdentifier: "fixture", modificationTime: 0, resourceNames: ["photo.jpg"],
                resourceTypes: [1], pixelWidth: 100, pixelHeight: 100, duration: 0, cleanupSupported: true),
            resourceIndex: 0)
    }

    func testTransientFailuresRetryButTrustAccessAndInvalidDataDoNot() {
        for status in [408, 425, 429, 500, 502, 503, 504] {
            XCTAssertTrue(BackupRetryPolicy.isTransient(ClientError.http(status, "")))
        }
        for status in [400, 401, 403, 404, 409, 413, 422] {
            XCTAssertFalse(BackupRetryPolicy.isTransient(ClientError.http(status, "")))
        }
        for code: URLError.Code in [.timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost] {
            XCTAssertTrue(BackupRetryPolicy.isTransient(URLError(code)))
        }
        for error: Error in [
            URLError(.serverCertificateUntrusted), URLError(.secureConnectionFailed), ClientError.signedOut,
            ClientError.invalid("Wrong checksum"), CocoaError(.fileWriteOutOfSpace),
        ] {
            XCTAssertFalse(BackupRetryPolicy.isTransient(error))
            XCTAssertFalse(BackupPresentation.failure(error).contains("retry automatically"))
        }
    }

    func testBackoffIsPersistedAndCapped() throws {
        var item = record()
        for delay: Double in [30, 60, 120, 240, 480, 960, 1920, 3600, 3600] {
            item.deferRetry(now: now)
            XCTAssertEqual(item.nextRetryAt, now.addingTimeInterval(delay))
        }
        item.requiresUserAction = true
        XCTAssertEqual(
            try JSONDecoder().decode(UploadRecord.self, from: JSONEncoder().encode(item)).requiresUserAction, true)
        item.requiresUserAction = nil
        XCTAssertNil(try JSONDecoder().decode(UploadRecord.self, from: JSONEncoder().encode(item)).requiresUserAction)
    }

    func testManualQueueGetsEarliestDeadlineAndPauseAndLibraryAreRespected() {
        var first = record()
        first.deferRetry(now: now)
        var second = record()
        second.nextRetryAt = now.addingTimeInterval(90)
        var ledger = AccountLedger()
        XCTAssertFalse(ledger.settings.automaticBackup)
        ledger.records = [second, first]
        XCTAssertEqual(BackupRetryPolicy.nextAttempt(ledger: ledger, library: library, now: now), first.nextRetryAt)
        XCTAssertNil(BackupRetryPolicy.nextAttempt(ledger: ledger, library: UUID(), now: now))
        XCTAssertNil(BackupRetryPolicy.nextAttempt(ledger: ledger, library: nil, now: now))
        ledger.settings.backupPaused = true
        XCTAssertNil(BackupRetryPolicy.nextAttempt(ledger: ledger, library: library, now: now))
        ledger.settings.backupPaused = false
        ledger.records[0].requiresUserAction = true
        ledger.records[1].remoteRemoved = true
        XCTAssertNil(BackupRetryPolicy.nextAttempt(ledger: ledger, library: library, now: now))
    }

    func testManifestRetryWaitsForChildrenAndIncludesGroupsWithoutFiles() {
        var item = record()
        var group = ResourceSetRecord(id: UUID(), libraryId: library, source: item.source, kind: "photo")
        group.nextRetryAt = now.addingTimeInterval(20)
        item.resourceSetId = group.id
        item.nextRetryAt = now.addingTimeInterval(90)
        var ledger = AccountLedger()
        ledger.records = [item]
        ledger.resourceSets = [group]
        XCTAssertEqual(BackupRetryPolicy.nextAttempt(ledger: ledger, library: library, now: now), item.nextRetryAt)
        ledger.records[0].requiresUserAction = true
        XCTAssertNil(BackupRetryPolicy.nextAttempt(ledger: ledger, library: library, now: now))
        ledger.records = []
        XCTAssertEqual(BackupRetryPolicy.nextAttempt(ledger: ledger, library: library, now: now), group.nextRetryAt)
        ledger.resourceSets?[0].requiresUserAction = true
        XCTAssertNil(BackupRetryPolicy.nextAttempt(ledger: ledger, library: library, now: now))
        XCTAssertEqual(BackupProgress(ledger: ledger, library: library).failed, 1)
    }

    func testIncompletePublicationCannotBePresentedAsCompleteBackup() {
        var item = record()
        item.phase = .ready
        item.evidence = BackupEvidence(
            id: item.id, sha256: item.sha256, size: item.size, available: true, createdAt: "")
        var ledger = AccountLedger()
        ledger.records = [item]
        XCTAssertTrue(BackupProgress(ledger: ledger, library: library).isComplete)
        ledger.resourceSets = [ResourceSetRecord(id: UUID(), libraryId: library, source: item.source, kind: "photo")]
        XCTAssertFalse(BackupProgress(ledger: ledger, library: library).isComplete)
        XCTAssertEqual(BackupPresentation.status(item, wholeItemPending: true), "Finishing backup")
        item.evidence = nil
        XCTAssertEqual(BackupPresentation.status(item), "Checking upload")
        item.error = "Technical error that should only appear in Details"
        item.deferRetry(now: now)
        XCTAssertEqual(BackupPresentation.status(item), "Waiting to retry")
        item.requiresUserAction = true
        XCTAssertEqual(BackupPresentation.status(item), "Backup stopped")
    }

    func testFailuresExplainRecoveryWithoutExposingRawDiagnostics() throws {
        XCTAssertTrue(BackupPresentation.failure(ClientError.http(400, "raw")).contains("server rejected"))
        XCTAssertFalse(BackupPresentation.failure(ClientError.http(400, "raw")).contains("automatically"))
        XCTAssertTrue(BackupPresentation.failure(ClientError.http(413, "")).contains("size limit"))
        XCTAssertTrue(BackupPresentation.failure(URLError(.serverCertificateUntrusted)).contains("certificate"))
        XCTAssertTrue(BackupPresentation.failure(CocoaError(.fileWriteOutOfSpace)).contains("Free some space"))
        XCTAssertEqual(
            BackupPresentation.recovery(
                saved: nil, diagnostic: "Server returned 400. Try again when the server is available."),
            BackupPresentation.failure(ClientError.http(400, "")))
        var item = record()
        item.recoveryMessage = BackupPresentation.failure(ClientError.http(400, ""))
        let restored = try JSONDecoder().decode(UploadRecord.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(restored.recoveryMessage, item.recoveryMessage)
        XCTAssertEqual(BackupPresentation.recovery(saved: "Specific recovery", diagnostic: "raw"), "Specific recovery")
    }

    @MainActor
    func testQueueOverlapsThreeJobsAndDrainsEveryItem() async throws {
        var active = 0
        var peak = 0
        var completed: Set<Int> = []
        try await BackupQueue.run(Array(0..<8)) { item in
            active += 1
            peak = max(peak, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(20))
            completed.insert(item)
        }
        XCTAssertEqual(peak, 3)
        XCTAssertEqual(active, 0)
        XCTAssertEqual(completed, Set(0..<8))
    }

    @MainActor
    func testFatalQueueFailureCancelsWorkersAndDoesNotStartMoreItems() async {
        var started = 0
        var active = 0
        do {
            try await BackupQueue.run(Array(0..<8)) { item in
                started += 1
                active += 1
                defer { active -= 1 }
                if item == 0 {
                    try await Task.sleep(for: .milliseconds(20))
                    throw ClientError.http(403, "Access revoked")
                }
                try await Task.sleep(for: .seconds(10))
            }
            XCTFail("Fatal errors must propagate")
        } catch {
            XCTAssertEqual(started, 3)
            XCTAssertEqual(active, 0)
        }
    }

    @MainActor
    func testPreparationRemainsSerialAndReleasesItsSlotAfterFailure() async throws {
        let preparation = BackupPreparation()
        var active = 0
        var peak = 0
        var completed = 0
        try await BackupQueue.run(Array(0..<6)) { item in
            do {
                try await preparation.run {
                    active += 1
                    peak = max(peak, active)
                    defer { active -= 1 }
                    try await Task.sleep(for: .milliseconds(10))
                    if item == 0 { throw ClientError.invalid("Export failed") }
                    completed += 1
                }
            } catch ClientError.invalid {}
        }
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(active, 0)
        XCTAssertEqual(completed, 5)
    }

    @MainActor
    func testWakeupActuallyRunsAndReplacementCancelsOldDeadline() async {
        let wakeup = BackupRetryWakeup()
        let cancelled = expectation(description: "Replaced deadline must not run")
        cancelled.isInverted = true
        let fired = expectation(description: "Due retry runs without another external event")
        wakeup.schedule(at: Date().addingTimeInterval(0.02)) { cancelled.fulfill() }
        wakeup.schedule(at: Date().addingTimeInterval(0.04)) { fired.fulfill() }
        await fulfillment(of: [fired, cancelled], timeout: 0.15)
    }

    @MainActor
    func testCancelledWakeupCannotResumePausedOrSignedOutWork() async {
        let wakeup = BackupRetryWakeup()
        let cancelled = expectation(description: "Cancelled retry must not run")
        cancelled.isInverted = true
        wakeup.schedule(at: Date().addingTimeInterval(0.02)) { cancelled.fulfill() }
        wakeup.cancel()
        await fulfillment(of: [cancelled], timeout: 0.1)
    }
}
