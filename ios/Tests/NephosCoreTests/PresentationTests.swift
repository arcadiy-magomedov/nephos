import CoreGraphics
import Foundation
import XCTest

@testable import NephosCore

final class PresentationTests: XCTestCase {
    private func asset(_ date: String, type: String = "image/heic", shared: String? = nil) -> Asset {
        Asset(
            id: UUID(), libraryId: UUID(), fileName: "fixture.heic", mediaType: type, size: 100,
            sha256: String(repeating: "a", count: 64), createdAt: date, hasPreview: true, sharedBy: shared)
    }

    func testAppearanceHasSystemDefaultAndExplicitOverrides() {
        XCTAssertEqual(AppAppearance.allCases, [.system, .light, .dark])
        XCTAssertEqual(AppAppearance(rawValue: "system"), .system)
        XCTAssertNil(AppAppearance(rawValue: "unsupported"))
    }

    func testChronologyUsesLocalDaysWithoutChangingAssets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -7 * 3600)!
        let first = asset("2026-10-31T00:30:00.123Z")
        let second = asset("2026-10-30T23:00:00Z", type: "video/quicktime")
        let third = asset("2026-10-31T20:00:00Z", shared: "Fixture owner")
        let unknown = asset("not-a-date")
        let days = MediaDay.groups([first, third, second, unknown], calendar: calendar)
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days[0].assets, [third])
        XCTAssertEqual(days[1].assets, [first, second])
        XCTAssertNil(days[2].date)
        XCTAssertEqual(MediaDay.groups([first, second, third], filter: .videos).flatMap(\.assets), [second])
        XCTAssertEqual(MediaDay.groups([first, second, third], filter: .shared).flatMap(\.assets), [third])
        XCTAssertEqual(MediaDay.groups([first, second], filter: .photos).flatMap(\.assets), [first])
    }

    func testFaceCropUsesUprightPreviewAndRejectsInvalidCoordinates() {
        func face(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> FaceObservation {
            FaceObservation(
                id: UUID(), assetId: UUID(), personId: nil, x: x, y: y, width: width,
                height: height, quality: "usable")
        }
        XCTAssertEqual(
            face(0.25, 0.1, 0.5, 0.5).cropRect(pixelWidth: 512, pixelHeight: 1000),
            CGRect(x: 128, y: 100, width: 256, height: 500))
        XCTAssertNotNil(face(0.5, 0.5, 0.5000001, 0.5).cropRect(pixelWidth: 512, pixelHeight: 512))
        for invalid in [face(-0.1, 0, 1, 1), face(0, 0, 2, 1), face(.nan, 0, 1, 1), face(0, 0, 0, 1)] {
            XCTAssertNil(invalid.cropRect(pixelWidth: 512, pixelHeight: 512))
        }
        XCTAssertNil(face(0, 0, 1, 1).cropRect(pixelWidth: 0, pixelHeight: 512))
    }

    func testPauseIsBackwardCompatibleAndIndependentOfAutomaticSettings() throws {
        let old = Data(
            #"{"automaticBackup":true,"automaticCleanup":false,"allowCellular":false,"cleanupWarningsAcknowledged":false}"#
                .utf8)
        var settings = try JSONDecoder().decode(BackupSettings.self, from: old)
        XCTAssertNil(settings.backupPaused)
        settings.backupPaused = true
        XCTAssertTrue(settings.automaticBackup)
        XCTAssertFalse(settings.automaticCleanup)
        XCTAssertEqual(try JSONDecoder().decode(BackupSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testShareScopeAndPersonInputValidation() throws {
        let library = UUID()
        let recipient = UUID().uuidString
        let id = UUID()
        XCTAssertNoThrow(
            try ShareInput(libraryId: library, recipientId: recipient, allAssets: false, assetIds: [id]).validate())
        XCTAssertNoThrow(
            try ShareInput(libraryId: library, recipientId: recipient, allAssets: true, assetIds: []).validate())
        for input in [
            ShareInput(libraryId: library, recipientId: recipient, allAssets: false, assetIds: []),
            ShareInput(libraryId: library, recipientId: recipient, allAssets: true, assetIds: [id]),
            ShareInput(libraryId: library, recipientId: recipient, allAssets: false, assetIds: [id, id]),
            ShareInput(libraryId: library, recipientId: "unknown", allAssets: false, assetIds: [id]),
        ] { XCTAssertThrowsError(try input.validate()) }
        XCTAssertNoThrow(try PersonNameInput(name: nil, aliases: []).validate())
        XCTAssertThrowsError(try PersonNameInput(name: String(repeating: "a", count: 121), aliases: []).validate())
        XCTAssertThrowsError(try PersonNameInput(name: "Name", aliases: [" "]).validate())
    }

    func testBackupCountsOnlyVerifiedCurrentLibraryResources() {
        let library = UUID()
        let source = SourceRevision(
            localIdentifier: "fixture", modificationTime: 0, resourceNames: [], resourceTypes: [],
            pixelWidth: 0, pixelHeight: 0, duration: 0, cleanupSupported: false)
        var record = UploadRecord(
            id: UUID(), libraryId: library, fileName: "fixture", mediaType: "image/jpeg", size: 100,
            sha256: String(repeating: "a", count: 64), source: source, resourceIndex: 0)
        var ledger = AccountLedger()
        ledger.records = [record]
        XCTAssertEqual(BackupProgress(ledger: ledger, library: library).pending, 1)
        record.phase = .ready
        ledger.records = [record]
        XCTAssertEqual(BackupProgress(ledger: ledger, library: library).verified, 0)
        record.evidence = BackupEvidence(
            id: record.id, sha256: record.sha256, size: 100, available: true, createdAt: "")
        ledger.records = [record]
        XCTAssertEqual(BackupProgress(ledger: ledger, library: library).fraction, 1)
        XCTAssertEqual(BackupProgress(ledger: ledger, library: UUID()).total, 0)
        record.remoteRemoved = true
        ledger.records = [record]
        XCTAssertEqual(BackupProgress(ledger: ledger, library: library).total, 0)
    }
}
