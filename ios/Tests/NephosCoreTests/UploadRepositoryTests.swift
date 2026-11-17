import Foundation
import Testing

@testable import NephosCore

@Suite
struct UploadRepositoryTests {
    private let scope = "server-user-library"

    private func repository() throws -> (SQLiteUploadRepository, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nephos-upload-test-\(UUID().uuidString)", isDirectory: true)
        return (
            try SQLiteUploadRepository(
                url: directory.appendingPathComponent("uploads.sqlite"),
                now: { Date(timeIntervalSince1970: 1_800_000_000) }),
            directory
        )
    }

    private func candidate(_ id: String, revision: String = "1", live: Bool = false) -> UploadCandidate {
        var resources = [
            UploadResourceDescriptor(
                type: 1, role: "photo", filename: "\(id).HEIC",
                uniformTypeIdentifier: "public.heic", mediaType: "image/heic", isPrimary: true)
        ]
        if live {
            resources.append(
                UploadResourceDescriptor(
                    type: 9, role: "pairedVideo", filename: "\(id).MOV",
                    uniformTypeIdentifier: "com.apple.quicktime-movie", mediaType: "video/quicktime", isPrimary: false))
        }
        return UploadCandidate(
            localIdentifier: id, sourceRevision: revision, kind: live ? "live-photo" : "single",
            capturedAt: nil, resources: resources)
    }

    private func succeed(_ item: UploadItem, in repository: SQLiteUploadRepository) async throws {
        var item = item
        for index in item.resources.indices {
            item.resources[index].phase = .ready
            item.resources[index].expectedBytes = 100
            item.resources[index].receivedBytes = 100
            item.resources[index].sha256 = String(repeating: "a", count: 64)
        }
        item.committed = true
        item.phase = .succeeded
        try await repository.update(item)
    }

    @Test
    func totalIncludesEntireInventoryAndGrowsBeyondTransferWindow() async throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await repository.setPolicy(.wiFiOnly, scope: scope)
        try await repository.beginDiscovery(scope: scope)
        try await repository.finishDiscovery(
            (0..<1001).map { candidate("photo-\($0)") }, checkpoint: Data([1]), scope: scope)
        let first = try await repository.snapshot(scope: scope, limit: 4)
        #expect(first.batch?.total == 1001)
        #expect(first.pending.count == 4)
        let firstBatch = try #require(first.batch)
        try await repository.finishDiscovery(
            (1001..<1101).map { candidate("photo-\($0)") }, checkpoint: Data([2]), scope: scope)
        let updated = try await repository.snapshot(scope: scope, limit: 4)
        #expect(updated.batch?.id == firstBatch.id)
        #expect(updated.batch?.total == 1101)
        #expect(updated.pendingCount == 1101)
        #expect(try await repository.checkpoint(scope: scope) == Data([2]))
    }

    @Test
    func repeatedDiscoveryAndRelaunchPreserveIdentityAndCounts() async throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await repository.setPolicy(.allNetworks, scope: scope)
        try await repository.finishDiscovery([candidate("photo")], checkpoint: nil, scope: scope)
        let first = try #require(try await repository.pending(scope: scope, limit: 1).first)
        try await repository.finishDiscovery([candidate("photo")], checkpoint: nil, scope: scope)
        let reopened = try SQLiteUploadRepository(url: directory.appendingPathComponent("uploads.sqlite"))
        let saved = try #require(try await reopened.pending(scope: scope, limit: 1).first)
        #expect(first.id == saved.id)
        #expect(first.resources.map(\.id) == saved.resources.map(\.id))
        #expect(try await reopened.snapshot(scope: scope, limit: 10).batch?.total == 1)
    }

    @Test
    func failuresKeepBatchOpenAndRetryDoesNotAddItems() async throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await repository.setPolicy(.allNetworks, scope: scope)
        try await repository.finishDiscovery([candidate("photo")], checkpoint: nil, scope: scope)
        var item = try #require(try await repository.pending(scope: scope, limit: 1).first)
        item.phase = .failed
        item.error = "Server storage is full."
        item.resources[0].phase = .failed
        item.resources[0].error = item.error
        try await repository.update(item)
        try await repository.finishDiscovery([], checkpoint: nil, scope: scope)
        let failed = try await repository.snapshot(scope: scope, limit: 10)
        #expect(failed.batch?.completedAt == nil)
        #expect(failed.batch?.failed == 1)
        #expect(failed.failed.first?.error == "Server storage is full.")
        try await repository.retryFailed(scope: scope)
        let retried = try await repository.snapshot(scope: scope, limit: 10)
        #expect(retried.batch?.total == 1)
        #expect(retried.batch?.id == item.batchID)
        #expect(retried.pending.first?.id == item.id)
        #expect(retried.failedCount == 0)
    }

    @Test
    func closesOnlyAfterDiscoveryReconciliationAndNewWorkStartsNewBatch() async throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await repository.setPolicy(.allNetworks, scope: scope)
        try await repository.finishDiscovery([candidate("first")], checkpoint: nil, scope: scope)
        let first = try #require(try await repository.pending(scope: scope, limit: 1).first)
        try await succeed(first, in: repository)
        #expect(try await repository.snapshot(scope: scope, limit: 10).batch?.completedAt == nil)
        try await repository.finishDiscovery([candidate("arrived-before-close")], checkpoint: nil, scope: scope)
        let active = try await repository.snapshot(scope: scope, limit: 10)
        #expect(active.batch?.total == 2)
        #expect(active.batch?.succeeded == 1)
        try await succeed(try #require(active.pending.first), in: repository)
        try await repository.finishDiscovery([], checkpoint: nil, scope: scope)
        #expect(try await repository.snapshot(scope: scope, limit: 10).batch?.completedAt != nil)
        try await repository.finishDiscovery([candidate("next-batch")], checkpoint: nil, scope: scope)
        let next = try await repository.snapshot(scope: scope, limit: 10)
        #expect(next.batch?.id != first.batchID)
        #expect(next.batch?.total == 1)
        #expect(next.succeededCount == 2)
    }

    @Test
    func livePhotoIsOneItemAndProgressIsWeightedByResourceBytes() async throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await repository.setPolicy(.allNetworks, scope: scope)
        try await repository.finishDiscovery([candidate("live", live: true)], checkpoint: nil, scope: scope)
        var item = try #require(try await repository.pending(scope: scope, limit: 1).first)
        item.resources[0].expectedBytes = 4
        item.resources[0].receivedBytes = 4
        item.resources[1].expectedBytes = 16
        item.resources[1].receivedBytes = 8
        item.phase = .uploading
        try await repository.update(item)
        #expect(item.progress == 0.6)
        #expect(try await repository.snapshot(scope: scope, limit: 10).batch?.total == 1)
        item.phase = .succeeded
        await #expect(throws: ClientError.self) { try await repository.update(item) }
        #expect(try await repository.snapshot(scope: scope, limit: 10).batch?.succeeded == 0)
    }

    @Test
    func sourceRevisionChangeReplacesPendingWorkWithoutGrowingTheBatch() async throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await repository.setPolicy(.allNetworks, scope: scope)
        try await repository.finishDiscovery([candidate("photo")], checkpoint: nil, scope: scope)
        let first = try #require(try await repository.pending(scope: scope, limit: 1).first)
        try await repository.finishDiscovery([candidate("photo", revision: "2")], checkpoint: nil, scope: scope)
        let current = try #require(try await repository.pending(scope: scope, limit: 1).first)
        #expect(current.id == first.id)
        #expect(current.resources.map(\.id) != first.resources.map(\.id))
        #expect(current.resourceSetID != first.resourceSetID)
        #expect(try await repository.snapshot(scope: scope, limit: 10).batch?.total == 1)
        await #expect(throws: CancellationError.self) { try await repository.update(first) }
    }

    @Test
    func disabledAccountsAndOtherScopesDoNotLeakOrScheduleWork() async throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await repository.finishDiscovery([candidate("photo")], checkpoint: nil, scope: scope)
        #expect(try await repository.snapshot(scope: scope, limit: 10).batch == nil)
        try await repository.setPolicy(.allNetworks, scope: scope)
        try await repository.finishDiscovery([candidate("photo")], checkpoint: nil, scope: scope)
        #expect(try await repository.snapshot(scope: "other-account", limit: 10).pendingCount == 0)
        try await repository.setPaused(true, scope: scope)
        try await repository.finishDiscovery([candidate("new-while-paused")], checkpoint: nil, scope: scope)
        let paused = try await repository.snapshot(scope: scope, limit: 10)
        #expect(paused.paused)
        #expect(!paused.canTransfer)
        #expect(paused.batch?.total == 2)
    }
}
