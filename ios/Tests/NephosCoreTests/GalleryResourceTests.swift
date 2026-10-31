import Foundation
import XCTest

@testable import NephosCore

final class GalleryResourceTests: XCTestCase {
    func testUpgradeResumesOnlyCompleteLegacyPhotoKitRejectionsOnce() throws {
        let original = group()
        var legacy = ResourceSetRecord(
            id: original.id, libraryId: original.libraryId, source: original.source, kind: "edited")
        legacy.requiresUserAction = true
        legacy.error = "Server returned 400. Try again when the server is available."
        var members = records(legacy)
        members[1].resourceRole = "unknown-16"
        var ledger = AccountLedger()
        ledger.records = members
        ledger.resourceSets = [legacy]
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(ledger.resumeLegacyPhotoKitPublications(now: now))
        XCTAssertEqual(ledger.resourceSets?[0].requiresUserAction, false)
        XCTAssertEqual(ledger.resourceSets?[0].nextRetryAt, now)
        XCTAssertEqual(ledger.records, members)
        XCTAssertFalse(ledger.resumeLegacyPhotoKitPublications())
        ledger.resourceSets?[0].requiresUserAction = true
        XCTAssertFalse(ledger.resumeLegacyPhotoKitPublications(), "A new rejection must not trigger a migration loop")
        ledger.resourceSets = [legacy]
        ledger.records.removeLast()
        XCTAssertFalse(ledger.resumeLegacyPhotoKitPublications(), "Incomplete sets must stay blocked")
        ledger.records = members
        ledger.resourceSets?[0].error = "Server returned 403. Access denied."
        XCTAssertFalse(ledger.resumeLegacyPhotoKitPublications(), "An upgrade must not bypass denied access")
    }

    func testResourceSetRequiresEveryVerifiedCanonicalPart() throws {
        let group = group()
        var records = records(group)
        XCTAssertThrowsError(try group.intent(records: Array(records.prefix(1))))
        records[1].phase = .uploading
        XCTAssertThrowsError(try group.intent(records: records))
        records[1].phase = .ready
        let intent = try group.intent(records: records)
        XCTAssertEqual(intent.resources.count, 2)
        XCTAssertEqual(intent.primaryAssetId, records[0].committedAssetID)
        XCTAssertNotEqual(intent.primaryAssetId, records[0].id)
        XCTAssertEqual(
            try JSONDecoder().decode(SourceRevision.self, from: Data(intent.sourceRevision.utf8)), group.source)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(UploadIntent(records[0]))) as? [String: Any])
        XCTAssertEqual(json["resourceSetId"] as? String, group.id.uuidString)
        records[1].evidence = BackupEvidence(
            id: records[1].id, sha256: records[1].sha256, size: records[1].size, available: true, createdAt: "")
        XCTAssertThrowsError(try group.intent(records: records))
        XCTAssertThrowsError(try group.intent(records: [records[0], records[0]]))
    }

    func testCompoundRestoreAllowlistDoesNotEnableCleanup() throws {
        let group = group()
        let records = records(group)
        let manifest = manifest(group, try group.intent(records: records))
        XCTAssertTrue(manifest.restoreSupported)
        XCTAssertNotNil(records[0].cleanupBlock(current: group.source))
        for kind in ["edited", "archive"] {
            let unsafe = ResourceManifest(
                id: manifest.id, libraryId: manifest.libraryId, kind: kind,
                sourceRevision: manifest.sourceRevision, primaryAssetId: manifest.primaryAssetId,
                resources: manifest.resources, createdAt: "")
            XCTAssertFalse(unsafe.restoreSupported)
        }
        let primary = Asset(
            id: manifest.primaryAssetId, libraryId: manifest.libraryId, fileName: "photo.jpg",
            mediaType: "image/jpeg", size: records[0].size, sha256: records[0].sha256, createdAt: "", hasPreview: false,
            resourceSetId: manifest.id)
        XCTAssertNoThrow(try manifest.validate(primary: primary))
        let wrong = Asset(
            id: primary.id, libraryId: UUID(), fileName: primary.fileName, mediaType: primary.mediaType,
            size: primary.size, sha256: primary.sha256, createdAt: "", hasPreview: false)
        XCTAssertThrowsError(try manifest.validate(primary: wrong))
    }

    func testRetentionRequiresEveryPartAndKnownAssurance() throws {
        let group = group()
        let manifest = manifest(group, try group.intent(records: records(group)))
        let date = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
        let holds = manifest.resources.map {
            RetentionHold(
                id: $0.assetId, sha256: $0.sha256, size: $0.size, available: true,
                holdId: UUID(), retainedUntil: date, assurance: "single-volume-no-independent-backup")
        }
        XCTAssertTrue(
            ResourceSetRetention(
                id: group.id, assurance: "single-volume-no-independent-backup", retainedUntil: date, resources: holds
            ).validates(manifest))
        XCTAssertFalse(
            ResourceSetRetention(
                id: group.id, assurance: "single-volume-no-independent-backup", retainedUntil: date,
                resources: Array(holds.prefix(1))
            ).validates(manifest))
        XCTAssertFalse(
            ResourceSetRetention(id: group.id, assurance: "unknown", retainedUntil: date, resources: holds).validates(
                manifest))
    }

    func testDeltaPagesRejectWrongBoundariesAndPartialRevision() throws {
        let library = UUID()
        let asset = asset(library: UUID())
        let valid = GalleryChanges(
            fromRevision: 10, toRevision: 11, targetRevision: 12, hasMore: true,
            changes: [
                GalleryRevision(
                    revision: 11, items: [GalleryChange(operation: "remove", assetId: asset.id, asset: nil)])
            ])
        XCTAssertNoThrow(try valid.validate(after: 10, through: 12, library: library))
        XCTAssertThrowsError(try valid.validate(after: 9, through: 12, library: library))
        XCTAssertThrowsError(try valid.validate(after: 10, through: 13, library: library))
        let crossed = GalleryChanges(
            fromRevision: 10, toRevision: 12, targetRevision: 12, hasMore: false,
            changes: [
                GalleryRevision(
                    revision: 12, items: [GalleryChange(operation: "upsert", assetId: asset.id, asset: asset)])
            ])
        XCTAssertThrowsError(try crossed.validate(after: 10, through: 12, library: library))
        let noProgress = GalleryChanges(
            fromRevision: 10, toRevision: 10, targetRevision: 12, hasMore: true, changes: [])
        XCTAssertThrowsError(try noProgress.validate(after: 10, through: 12, library: library))
        let incomplete = GalleryChanges(
            fromRevision: 10, toRevision: 11, targetRevision: 12, hasMore: false, changes: valid.changes)
        XCTAssertThrowsError(try incomplete.validate(after: 10, through: 12, library: library))
        let repeated = GalleryChanges(
            fromRevision: 10, toRevision: 12, targetRevision: 12, hasMore: false, changes: valid.changes + valid.changes
        )
        XCTAssertThrowsError(try repeated.validate(after: 10, through: 12, library: library))
    }

    func testDateNavigationAndExactTimestampTieAnchor() throws {
        XCTAssertEqual(try GalleryDates.endOfBucket("2020").createdAt, "2021-01-01T00:00:00Z")
        XCTAssertEqual(try GalleryDates.endOfBucket("2020-02").createdAt, "2020-03-01T00:00:00Z")
        XCTAssertEqual(try GalleryDates.endOfBucket("2020-02-29").createdAt, "2020-03-01T00:00:00Z")
        XCTAssertThrowsError(try GalleryDates.endOfBucket("2020-02-30"))
        XCTAssertThrowsError(try GalleryDates.endOfBucket("2020-13"))
        let anchor = GalleryCursor(
            createdAt: "2020-01-01T01:02:03.123456Z", id: UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!)
        let inclusive = GalleryDates.inclusiveAnchor(anchor)
        XCTAssertEqual(inclusive.createdAt, anchor.createdAt)
        XCTAssertEqual(inclusive.id.uuidString, "00000000-0000-0000-0000-000000000100")
    }

    func testRetainedWindowPersistsAndIsAccountLibraryIsolated() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
            ".test-work/\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LedgerStore(root: root)
        let library = Library(id: UUID(), name: "Photos")
        let account = String(repeating: "a", count: 64)
        let other = String(repeating: "b", count: 64)
        let item = asset(library: library.id)
        var window = GalleryWindow()
        try window.append(AssetPage(items: [item], nextCursor: nil), libraryID: library.id)
        let snapshot = GallerySnapshot(id: UUID(), revision: 32, accessGeneration: 4, expiresAt: "", totalCount: 1)
        let cache = RetainedGallery(
            library: library, snapshot: snapshot, window: window,
            anchor: GalleryCursor(createdAt: item.createdAt, id: item.id), updatedAt: Date())
        try store.saveGallery(cache, account: account)
        let loaded = try XCTUnwrap(store.loadGallery(account: account, library: library.id))
        XCTAssertEqual(loaded.snapshot, snapshot)
        XCTAssertEqual(loaded.window.items, [item])
        XCTAssertEqual(loaded.anchor?.id, item.id)
        XCTAssertNil(try store.loadGallery(account: other, library: library.id))
        XCTAssertNil(try store.loadGallery(account: account, library: UUID()))
        var ledger = AccountLedger()
        ledger.resourceSets = [group()]
        try store.save(ledger, account: account)
        XCTAssertEqual(try store.load(account: account).resourceSets?.first?.source, ledger.resourceSets?.first?.source)
        try store.clearGallery(account: account)
        XCTAssertNil(try store.loadGallery(account: account, library: library.id))
        XCTAssertEqual(try store.load(account: account).resourceSets?.count, 1)
    }

    func testLegacyLedgerAndAssetDecodeWithoutNewFields() throws {
        let ledger = try JSONDecoder().decode(
            AccountLedger.self,
            from: Data(
                """
                {"version":1,"settings":{"automaticBackup":false,"automaticCleanup":false,"allowCellular":false,"cleanupWarningsAcknowledged":false},"records":[]}
                """.utf8))
        XCTAssertNil(ledger.resourceSets)
        let item = asset(library: UUID())
        XCTAssertNil(try JSONDecoder().decode(Asset.self, from: JSONEncoder().encode(item)).resourceSetId)
        var old = group().source
        let current = old
        old.resourceUTIs = nil
        XCTAssertTrue(
            old.matchesCurrentRevision(current),
            "Adding revision metadata must not cause legacy originals to be reuploaded.")
        var changed = current
        changed.resourceUTIs = ["public.png", "com.apple.quicktime-movie"]
        XCTAssertFalse(current.matchesCurrentRevision(changed))
    }

    func testRangeValidationRejectsWholeFilesRedirectsAndIncorrectOffsets() throws {
        let url = URL(string: "https://server.test/original")!
        let valid = HTTPURLResponse(
            url: url, statusCode: 206, httpVersion: nil,
            headerFields: ["Content-Range": "bytes 5-12/100", "Content-Length": "8"])!
        XCTAssertNoThrow(try MediaRange.validate(valid, offset: 5, length: 8, size: 100))
        XCTAssertThrowsError(try MediaRange.validate(valid, offset: 4, length: 8, size: 100))
        XCTAssertThrowsError(try MediaRange.validate(valid, offset: 5, length: 8, size: 101))
        for status in [200, 302, 401, 403, 404, 416] {
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Length": "100"])!
            XCTAssertThrowsError(try MediaRange.validate(response, offset: 0, length: 8, size: 100))
        }
        let compressed = HTTPURLResponse(
            url: url, statusCode: 206, httpVersion: nil,
            headerFields: ["Content-Range": "bytes 5-12/100", "Content-Length": "8", "Content-Encoding": "gzip"])!
        XCTAssertThrowsError(try MediaRange.validate(compressed, offset: 5, length: 8, size: 100))
    }

    private func group() -> ResourceSetRecord {
        ResourceSetRecord(
            id: UUID(), libraryId: UUID(),
            source: SourceRevision(
                localIdentifier: "local",
                modificationTime: 123, resourceNames: ["photo.jpg", "paired.mov"], resourceTypes: [1, 9],
                pixelWidth: 100,
                pixelHeight: 100, duration: 2, cleanupSupported: false, creationTime: 100,
                resourceUTIs: ["public.jpeg", "com.apple.quicktime-movie"]), kind: "live-photo")
    }
    private func records(_ group: ResourceSetRecord) -> [UploadRecord] {
        (0..<2).map { index in
            var record = UploadRecord(
                id: UUID(), libraryId: group.libraryId, fileName: group.source.resourceNames[index],
                mediaType: index == 0 ? "image/jpeg" : "video/quicktime", size: 10,
                sha256: String(repeating: index == 0 ? "a" : "b", count: 64), source: group.source, resourceIndex: index
            )
            record.phase = .ready
            record.assetId = UUID()
            record.evidence = BackupEvidence(
                id: record.committedAssetID, sha256: record.sha256, size: record.size, available: true, createdAt: "")
            record.resourceSetId = group.id
            record.resourceRole = index == 0 ? "photo" : "pairedVideo"
            record.uniformTypeIdentifier = group.source.resourceUTIs![index]
            return record
        }
    }
    private func manifest(_ group: ResourceSetRecord, _ intent: ResourceSetIntent) -> ResourceManifest {
        ResourceManifest(
            id: group.id, libraryId: group.libraryId, kind: intent.kind,
            sourceRevision: intent.sourceRevision, primaryAssetId: intent.primaryAssetId, resources: intent.resources,
            createdAt: "")
    }
    private func asset(library: UUID) -> Asset {
        Asset(
            id: UUID(), libraryId: library, fileName: "photo.jpg", mediaType: "image/jpeg", size: 10,
            sha256: String(repeating: "a", count: 64), createdAt: "2020-01-01T00:00:00Z", hasPreview: false)
    }
}
