import Foundation
import XCTest

@testable import NephosCore

@MainActor
private final class TrashTestTokens: AccessTokenProviding {
    func accessToken() async throws -> String { "fixture" }
}

final class TrashTests: XCTestCase {
    private let date = "2026-11-01T12:00:00+01:00"
    private let purge = "2026-12-01T12:00:00+01:00"

    func testTrashPageDecodesConfirmedContractAndValidatesCursor() throws {
        let item = trashItem()
        let page = TrashPage(items: [item], nextCursor: TrashCursor(deletedAt: date, id: item.id))
        let decoded = try JSONDecoder().decode(TrashPage.self, from: JSONEncoder().encode(page))
        try decoded.validate(before: nil)
        XCTAssertEqual(decoded.items, [item])
        XCTAssertThrowsError(try decoded.validate(before: decoded.nextCursor))
        XCTAssertThrowsError(
            try TrashPage(
                items: [item, item], nextCursor: nil
            ).validate(before: nil))
        XCTAssertThrowsError(
            try TrashPage(
                items: [item], nextCursor: TrashCursor(deletedAt: date, id: UUID())
            ).validate(before: nil))
        XCTAssertThrowsError(
            try TrashPage(
                items: [TrashItem(asset: item.asset, deletedAt: date, purgeAfter: date)],
                nextCursor: nil
            ).validate(before: nil))
        var shared = item.asset
        shared.sharedBy = "another owner"
        XCTAssertThrowsError(
            try TrashPage(
                items: [TrashItem(asset: shared, deletedAt: date, purgeAfter: purge)],
                nextCursor: nil
            ).validate(before: nil))
        XCTAssertThrowsError(
            try TrashPage(
                items: [TrashItem(asset: item.asset, deletedAt: "invalid", purgeAfter: purge)],
                nextCursor: nil
            ).validate(before: nil))
    }

    @MainActor
    func testTrashPagingEscapesOffsetAndPreviewUsesOwnerEndpoint() async throws {
        let api = API(
            connection: Connection(
                baseURL: URL(string: "https://photos.example.net")!,
                config: ServerConfig(
                    serverId: "fixture", issuer: "https://photos.example.net/identity",
                    clientId: "nephos-ios", maxUploadBytes: 100, chunkSize: 4_194_304),
                allowDevelopmentHTTP: false),
            auth: TrashTestTokens())
        let id = UUID()
        let preview = try await api.trashPreviewRequest(id, size: .screen)
        XCTAssertEqual(preview.url?.path, "/v1/trash/\(id)/preview")
        XCTAssertEqual(preview.url?.query, "size=1280")
        XCTAssertEqual(preview.value(forHTTPHeaderField: "Accept"), "image/jpeg")
        let url = try api.endpoint(
            "v1/trash",
            query: [
                URLQueryItem(name: "before", value: date),
                URLQueryItem(name: "beforeId", value: id.uuidString),
            ])
        XCTAssertTrue(url.absoluteString.contains("%2B01:00"))
        api.invalidate()
        do {
            _ = try await api.trashPreviewRequest(id)
            XCTFail("An old account API must not authorize a trash preview.")
        } catch is CancellationError {}
    }

    func testDeletionIncludesOffscreenUploadedResourcesAndNotPendingIDs() throws {
        let library = UUID()
        var saved = record(library: library, identifier: "offscreen")
        saved.phase = .ready
        saved.assetId = UUID()
        var constituent = record(library: library, identifier: "offscreen")
        constituent.phase = .ready
        let pending = record(library: library, identifier: "offscreen")
        var ledger = AccountLedger()
        ledger.selectedLibraryID = library
        ledger.records = [saved, constituent, pending]
        let selected = UUID()
        let ids = ledger.deletionAssets(assetIDs: [selected], localIdentifiers: ["offscreen"])
        XCTAssertEqual(ids, [selected, saved.committedAssetID, constituent.committedAssetID])
        XCTAssertFalse(ids.contains(pending.id))
        ledger.suppressDeletion(assetIDs: ids, localIdentifiers: ["offscreen"])
        XCTAssertTrue(ledger.records.allSatisfy { $0.remoteRemoved == true && !$0.needsTransfer })
        XCTAssertTrue(ledger.suppresses("offscreen", library: library))
        XCTAssertFalse(ledger.suppresses("offscreen", library: UUID()))
        XCTAssertTrue(ledger.trackedRecords(for: saved.committedAssetID).contains(saved.id))
    }

    func testSuppressionSurvivesRestartNewRevisionAndEmptyLedger() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".trash-tests-\(UUID())", isDirectory: true)
        defer {
            do { try FileManager.default.removeItem(at: root) } catch {
                XCTFail("Could not remove test ledger: \(error)")
            }
        }
        let store = try LedgerStore(root: root)
        let account = String(repeating: "a", count: 64)
        let library = UUID()
        var ledger = AccountLedger()
        ledger.selectedLibraryID = library
        ledger.suppressDeletion(assetIDs: [], localIdentifiers: ["not-yet-uploaded"])
        try store.save(ledger, account: account)
        var restarted = try store.load(account: account)
        XCTAssertTrue(restarted.suppresses("not-yet-uploaded", library: library))
        let revision = record(library: library, identifier: "not-yet-uploaded", modificationTime: 11)
        restarted.records.append(revision)
        XCTAssertTrue(restarted.suppresses(revision.source.localIdentifier, library: library))
        restarted.suppressDeletion(assetIDs: [], localIdentifiers: ["not-yet-uploaded"])
        XCTAssertEqual(restarted.suppressedSources?.count, 1)
        var legacy = AccountLedger()
        var removed = record(library: library, identifier: "legacy")
        removed.remoteRemoved = true
        legacy.records = [removed]
        XCTAssertTrue(legacy.suppresses("legacy", library: library))
        let data = try JSONEncoder().encode(AccountLedger())
        let old = try JSONDecoder().decode(AccountLedger.self, from: data)
        XCTAssertNil(old.suppressedSources)
    }

    func testGalleryRemovalKeepsUnaffectedItems() throws {
        let first = trashItem()
        let second = trashItem(library: first.asset.libraryId)
        var window = GalleryWindow()
        try window.append(
            AssetPage(items: [first.asset, second.asset], nextCursor: nil),
            libraryID: first.asset.libraryId)
        window.remove([first.id])
        XCTAssertEqual(window.items.map(\.id), [second.id])
        XCTAssertTrue(window.hasLoaded)
    }

    func testSuppressedRevisionsAndUnpublishedGroupsDoNotScheduleRetries() {
        let library = UUID()
        var ledger = AccountLedger()
        ledger.selectedLibraryID = library
        var queued = record(library: library, identifier: "suppressed")
        ledger.records = [queued]
        let group = ResourceSetRecord(
            id: UUID(), libraryId: library, source: queued.source, kind: "single")
        ledger.resourceSets = [group]
        XCTAssertNotNil(BackupRetryPolicy.nextAttempt(ledger: ledger, library: library))
        ledger.suppressDeletion(assetIDs: [], localIdentifiers: ["suppressed"])
        queued.remoteRemoved = nil
        ledger.records = [queued]
        XCTAssertNil(BackupRetryPolicy.nextAttempt(ledger: ledger, library: library))
        ledger.resourceSets = [
            ResourceSetRecord(
                id: group.id, libraryId: library,
                source: record(library: library, identifier: "suppressed", modificationTime: 11).source, kind: "single")
        ]
        XCTAssertNil(BackupRetryPolicy.nextAttempt(ledger: ledger, library: library))
    }

    func testSecondaryPublicationRemovalDoesNotTombstoneCompoundOriginals() {
        let library = UUID()
        var primary = record(library: library, identifier: "live")
        var secondary = record(library: library, identifier: "live")
        var group = ResourceSetRecord(id: UUID(), libraryId: library, source: primary.source, kind: "live-photo")
        primary.resourceSetId = group.id
        secondary.resourceSetId = group.id
        group.manifest = ResourceManifest(
            id: group.id, libraryId: library, kind: group.kind, sourceRevision: "fixture",
            primaryAssetId: primary.id,
            resources: [primary, secondary].map {
                ResourcePart(
                    assetId: $0.id, role: "photo", sha256: $0.sha256, size: $0.size,
                    fileName: $0.fileName, uniformTypeIdentifier: "public.jpeg")
            }, createdAt: date)
        var ledger = AccountLedger()
        ledger.records = [primary, secondary]
        ledger.resourceSets = [group]
        XCTAssertEqual(ledger.trackedRecords(for: primary.id), [primary.id, secondary.id])
        XCTAssertTrue(ledger.trackedRecords(for: secondary.id).isEmpty)
        ledger.suppressDeletion(assetIDs: [primary.id], localIdentifiers: [])
        XCTAssertTrue(ledger.records.allSatisfy { $0.remoteRemoved == true })
    }

    private func trashItem(library: UUID = UUID()) -> TrashItem {
        TrashItem(
            asset: Asset(
                id: UUID(), libraryId: library, fileName: "photo.jpg", mediaType: "image/jpeg",
                size: 8, sha256: String(repeating: "a", count: 64), createdAt: date, hasPreview: true),
            deletedAt: date, purgeAfter: purge)
    }

    private func record(library: UUID, identifier: String, modificationTime: Double = 10) -> UploadRecord {
        UploadRecord(
            id: UUID(), libraryId: library, fileName: "photo.jpg", mediaType: "image/jpeg",
            size: 8, sha256: String(repeating: "a", count: 64),
            source: SourceRevision(
                localIdentifier: identifier, modificationTime: modificationTime, resourceNames: ["photo.jpg"],
                resourceTypes: [1], pixelWidth: 10, pixelHeight: 10, duration: 0, cleanupSupported: true),
            resourceIndex: 0)
    }
}
