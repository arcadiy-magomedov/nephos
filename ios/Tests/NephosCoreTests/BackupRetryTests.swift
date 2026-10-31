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
        XCTAssertEqual(BackupPresentation.status(item), "Needs attention")
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
