import Foundation
import XCTest

@testable import NephosCore

final class UnifiedGalleryTests: XCTestCase {
    private let library = UUID()
    private func asset(_ id: UUID = UUID(), shared: Bool = false) -> Asset {
        Asset(
            id: id, libraryId: library, fileName: "capture.jpg", mediaType: "image/jpeg", size: 10,
            sha256: String(repeating: "a", count: 64), createdAt: "2026-09-21T10:00:00Z",
            hasPreview: true, sharedBy: shared ? "another-user" : nil)
    }
    private func record(_ asset: Asset, identifier: String, removed: Bool = false) -> UploadRecord {
        var record = UploadRecord(
            id: UUID(), libraryId: library, fileName: asset.fileName, mediaType: asset.mediaType, size: asset.size,
            sha256: asset.sha256,
            source: SourceRevision(
                localIdentifier: identifier, modificationTime: 0, resourceNames: [asset.fileName],
                resourceTypes: [1], pixelWidth: 10, pixelHeight: 10, duration: 0, cleanupSupported: true),
            resourceIndex: 0)
        record.phase = .ready
        record.assetId = asset.id
        record.remoteRemoved = removed
        return record
    }
    func testMergeDeduplicatesRemoteAndCombinesLocalUploadedSharedStates() throws {
        let owned = asset()
        let shared = asset(shared: true)
        let video = LocalGalleryAsset(identifier: "video", date: Date(), isVideo: true)
        let input = UnifiedGalleryInput(
            remote: [owned, shared, owned],
            local: [
                LocalGalleryAsset(identifier: "local", date: Date(), isVideo: false), video,
            ], records: [record(owned, identifier: "local")], readOnlyLibraries: [], selectedLibrary: library,
            filter: .all)
        let snapshot = try UnifiedGallerySnapshot.build(input)
        XCTAssertEqual(snapshot.items.count, 3)
        let merged = try XCTUnwrap(snapshot.items.first { $0.asset?.id == owned.id })
        XCTAssertEqual(merged.id, "local:local")
        XCTAssertEqual(merged.localIdentifier, "local")
        XCTAssertTrue(merged.uploaded)
        XCTAssertFalse(merged.shared)
        XCTAssertTrue(snapshot.items.first { $0.asset?.id == shared.id }?.shared == true)
        XCTAssertTrue(snapshot.items.first { $0.localIdentifier == "video" }?.isVideo == true)
        XCTAssertEqual(snapshot.days.flatMap(\.items).map(\.id), snapshot.filtered.map(\.id))
    }
    func testUploadPublicationPreservesLocalIdentityDateOrderAndDay() throws {
        let remote = asset()
        let locals = [
            LocalGalleryAsset(identifier: "capture", date: Date(timeIntervalSince1970: 100), isVideo: false),
            LocalGalleryAsset(identifier: "neighbor", date: Date(timeIntervalSince1970: 200), isVideo: false),
        ]
        func snapshot(_ remoteAssets: [Asset]) throws -> UnifiedGallerySnapshot {
            try UnifiedGallerySnapshot.build(
                UnifiedGalleryInput(
                    remote: remoteAssets, local: locals, records: [record(remote, identifier: "capture")],
                    readOnlyLibraries: [], selectedLibrary: library, filter: .all))
        }
        let before = try snapshot([])
        let after = try snapshot([remote])
        XCTAssertEqual(before.filtered.map(\.id), after.filtered.map(\.id))
        XCTAssertEqual(before.filtered.map(\.date), after.filtered.map(\.date))
        XCTAssertEqual(before.days.map(\.id), after.days.map(\.id))
        XCTAssertTrue(try XCTUnwrap(after.items.first { $0.id == "local:capture" }).uploaded)
    }

    func testLocalResourceConstituentsCannotCreateDuplicateStableIDs() throws {
        let photo = asset()
        let video = asset()
        let result = try UnifiedGallerySnapshot.build(
            UnifiedGalleryInput(
                remote: [photo, video],
                local: [LocalGalleryAsset(identifier: "live", date: nil, isVideo: false)],
                records: [record(photo, identifier: "live"), record(video, identifier: "live")],
                readOnlyLibraries: [], selectedLibrary: library, filter: .all))
        XCTAssertEqual(result.items.map(\.id), ["local:live"])
        XCTAssertNil(result.items.first?.date)
    }

    func testRemovedSourcesAreNotShownUploadedAndReadOnlyFilterIncludesSharedLibrary() throws {
        let remote = asset()
        let input = UnifiedGalleryInput(
            remote: [remote],
            local: [LocalGalleryAsset(identifier: "removed", date: nil, isVideo: false)],
            records: [record(asset(), identifier: "removed", removed: true)],
            readOnlyLibraries: [library], selectedLibrary: library, filter: .shared)
        let snapshot = try UnifiedGallerySnapshot.build(input)
        XCTAssertEqual(snapshot.filtered.map(\.id), [GalleryMedia.remoteID(remote.id)])
        XCTAssertFalse(try XCTUnwrap(snapshot.items.first { $0.localIdentifier == "removed" }).uploaded)
    }
    func testEqualDatesHaveStableOrderingAndVideoFilter() throws {
        let locals = [
            LocalGalleryAsset(identifier: "b", date: nil, isVideo: true),
            LocalGalleryAsset(identifier: "a", date: nil, isVideo: true),
            LocalGalleryAsset(identifier: "c", date: nil, isVideo: false),
        ]
        let snapshot = try UnifiedGallerySnapshot.build(
            UnifiedGalleryInput(
                remote: [], local: locals, records: [], readOnlyLibraries: [], selectedLibrary: library,
                filter: .videos))
        XCTAssertEqual(snapshot.filtered.map(\.id), ["local:a", "local:b"])
        XCTAssertEqual(snapshot.days.count, 1)
    }
    @MainActor
    func testCancelledSnapshotCannotPublishAndWorkExecutesOffMainThread() async throws {
        let input = UnifiedGalleryInput(
            remote: [], local: [], records: [], readOnlyLibraries: [], selectedLibrary: library, filter: .all)
        let worker = Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            return try UnifiedGallerySnapshot.build(input)
        }
        _ = try await worker.value
        let remote = asset()
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try UnifiedGallerySnapshot.build(
                UnifiedGalleryInput(
                    remote: [remote], local: [], records: [], readOnlyLibraries: [],
                    selectedLibrary: nil, filter: .all))
        }
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled gallery work must not produce a snapshot.")
        } catch is CancellationError {}
    }
}
