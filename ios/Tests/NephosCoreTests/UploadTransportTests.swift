import Foundation
import Testing

@testable import NephosCore

@Suite
struct UploadTransportTests {
    @Test
    func livePhotoWaitsForBothOriginalsAndManifestCommit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nephos-transfer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try UploadDestination.fixture()
        let repository = try SQLiteUploadRepository(url: directory.appendingPathComponent("queue.sqlite"))
        let remote = UploadRemoteFake()
        let transport = UploadTransportFake()
        let events = UploadEventStore(directory: directory)
        let coordinator = UploadCoordinator(
            destination: destination, repository: repository,
            source: UploadPhotoSourceFake([.fixture(live: true)]), client: remote,
            transport: transport, files: UploadFileStore(directory: directory), events: events)
        try await repository.setPolicy(.allNetworks, scope: destination.scope)

        try await coordinator.process(discover: true, allowsPreparation: true)
        let scheduled = try await repository.snapshot(scope: destination.scope, limit: 10)
        #expect(scheduled.batch?.total == 1)
        #expect(scheduled.batch?.succeeded == 0)
        let transfers = await transport.active()
        #expect(transfers.count == 2)
        for transfer in transfers { await events.update(transfer, bytes: transfer.bytes / 2) }
        try await coordinator.process(discover: false, allowsPreparation: true)
        #expect(try await repository.snapshot(scope: destination.scope, limit: 10).pending.first?.progress == 0.5)
        for transfer in transfers {
            await remote.accept(transfer)
            try events.record(
                UploadTransferReceipt(
                    transfer: transfer, status: 204, error: nil, cancelled: false, completedAt: Date()))
            await transport.finish(transfer)
        }
        try await coordinator.process(discover: false, allowsPreparation: true)

        let verifying = try await repository.snapshot(scope: destination.scope, limit: 10)
        #expect(verifying.batch?.succeeded == 0)
        #expect(verifying.pending.first?.phase == .verifying)
        #expect(await remote.committed == nil)
        await remote.verifyAll()
        try await coordinator.process(discover: false, allowsPreparation: true)
        let completed = try await repository.snapshot(scope: destination.scope, limit: 10)
        #expect(completed.batch?.succeeded == 1)
        #expect(completed.batch?.completedAt != nil)
        #expect(completed.succeeded.first?.committed == true)
        #expect(await remote.committed?.resources.count == 2)
        #expect(try await events.receipts(scope: destination.scope).isEmpty)
    }

    @Test
    func chunkRequestUsesEnrolledOriginAndNetworkPolicyWithoutPlistConfiguration() async throws {
        let destination = try UploadDestination.fixture()
        let store = UploadSessionStorageFake(destination: destination)
        let client = UploadHTTPClient(
            connection: destination.connection,
            authorization: UploadAuthorization(account: destination.accountKey, store: store))
        var resource = try #require(
            UploadIdentity.resources(
                scope: destination.scope, candidate: .fixture()
            ).first)
        resource.expectedBytes = Int64(UploadChunk.byteCount) + 3
        resource.sha256 = String(repeating: "a", count: 64)

        let request = try await client.uploadRequest(resource, part: 1, policy: .wiFiOnly)

        #expect(
            request.url?.absoluteString
                == "\(destination.connection.baseURL.absoluteString)/v1/uploads/\(resource.id.uuidString)/parts/1")
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Content-Length") == "3")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only-access")
        #expect(!request.allowsCellularAccess)
        #expect(!request.allowsExpensiveNetworkAccess)
        await #expect(throws: ClientError.self) {
            try await client.uploadRequest(resource, part: 2, policy: .wiFiOnly)
        }
        await #expect(throws: ClientError.self) {
            try await client.uploadRequest(resource, part: 0, policy: .disabled)
        }
    }

    @Test
    func durableReceiptSurvivesProcessRecreationAndRejectsInvalidTaskIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nephos-receipt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = UploadTransfer(
            scope: "fixture", itemID: UploadIdentity.id(["item"]), generation: UploadIdentity.id(["generation"]),
            resourceID: UploadIdentity.id(["resource"]), part: 7, bytes: 42)
        let events = UploadEventStore(directory: directory)

        try events.record(
            UploadTransferReceipt(
                transfer: transfer, status: 204, error: nil, cancelled: false, completedAt: Date()))
        let recreated = UploadEventStore(directory: directory)

        let receipts = try await recreated.receipts(scope: "fixture")
        #expect(receipts.count == 1)
        #expect(receipts.first?.transfer == transfer)
        #expect(try UploadTransfer.parse(transfer.taskDescription()) == transfer)
        #expect(throws: ClientError.self) { try UploadTransfer.parse(nil) }
        #expect(try await recreated.receipts(scope: "other-account").isEmpty)
        try await recreated.acknowledge(try #require(receipts.first))
        #expect(try await recreated.receipts(scope: "fixture").isEmpty)
    }

    @Test
    func revokedSessionPropagatesSignedOutWithoutMarkingPendingItemsFailed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nephos-signout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try UploadDestination.fixture()
        let repository = try SQLiteUploadRepository(url: directory.appendingPathComponent("queue.sqlite"))
        let coordinator = UploadCoordinator(
            destination: destination, repository: repository,
            source: UploadPhotoSourceFake([.fixture()]), client: SignedOutUploadRemote(),
            transport: UploadTransportFake(), files: UploadFileStore(directory: directory),
            events: UploadEventStore(directory: directory))
        try await repository.setPolicy(.allNetworks, scope: destination.scope)

        await #expect(throws: ClientError.self) {
            try await coordinator.process(discover: true, allowsPreparation: true)
        }
        let snapshot = try await repository.snapshot(scope: destination.scope, limit: 10)
        #expect(snapshot.failedCount == 0)
        #expect(snapshot.pendingCount == 1)
    }

    @Test
    func unauthorizedReceiptAcknowledgesBeforeRefreshAndNeverBlocksLaterReceipts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nephos-401-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try UploadDestination.fixture()
        let repository = try SQLiteUploadRepository(url: directory.appendingPathComponent("queue.sqlite"))
        let remote = FailingRefreshRemote()
        let transport = UploadTransportFake()
        let events = UploadEventStore(directory: directory)
        let coordinator = UploadCoordinator(
            destination: destination, repository: repository,
            source: UploadPhotoSourceFake([.fixture(live: true)]), client: remote,
            transport: transport, files: UploadFileStore(directory: directory), events: events)
        try await repository.setPolicy(.allNetworks, scope: destination.scope)

        try await coordinator.process(discover: true, allowsPreparation: true)
        let transfers = await transport.active()
        #expect(transfers.count == 2)
        try events.record(
            UploadTransferReceipt(
                transfer: transfers[0], status: 401, error: nil, cancelled: false, completedAt: Date()))
        try events.record(
            UploadTransferReceipt(
                transfer: transfers[1], status: 204, error: nil, cancelled: false, completedAt: Date()))

        try await coordinator.process(discover: false, allowsPreparation: true)
        #expect(try await events.receipts(scope: destination.scope).isEmpty)
        let snapshot = try await repository.snapshot(scope: destination.scope, limit: 10)
        let item = try #require(snapshot.pending.first)
        let confirmed = item.resources.first { $0.id == transfers[1].resourceID }
        #expect(confirmed?.confirmedParts.contains(transfers[1].part) == true)
        #expect(snapshot.notice?.contains("sign-in") == true)
    }

    @Test
    func transientIdpHttpErrorKeepsPendingItemsAndRetriesWithoutFailing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nephos-503-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try UploadDestination.fixture()
        let repository = try SQLiteUploadRepository(url: directory.appendingPathComponent("queue.sqlite"))
        let coordinator = UploadCoordinator(
            destination: destination, repository: repository,
            source: UploadPhotoSourceFake([.fixture()]), client: TransientHTTP503Remote(),
            transport: UploadTransportFake(), files: UploadFileStore(directory: directory),
            events: UploadEventStore(directory: directory))
        try await repository.setPolicy(.allNetworks, scope: destination.scope)

        try await coordinator.process(discover: true, allowsPreparation: true)
        let snapshot = try await repository.snapshot(scope: destination.scope, limit: 10)
        #expect(snapshot.failedCount == 0)
        #expect(snapshot.pendingCount == 1)
        #expect(snapshot.notice?.contains("503") == true)
    }
}

private actor TransientHTTP503Remote: UploadRemote {
    func create(_ resource: UploadResource, item: UploadItem, library: UUID) throws -> UploadResourceStatus {
        throw ClientError.http(503, "Identity service unavailable.")
    }
    func retry(_ resource: UploadResource, item: UploadItem, library: UUID) throws -> UploadResourceStatus {
        throw ClientError.http(503, "Identity service unavailable.")
    }
    func complete(_ resource: UploadResource) throws -> UploadResourceStatus {
        throw ClientError.http(503, "Identity service unavailable.")
    }
    func uploadRequest(_ resource: UploadResource, part: Int, policy: UploadPolicy) throws -> URLRequest {
        throw ClientError.http(503, "Identity service unavailable.")
    }
    func manifest(_ item: UploadItem) -> UploadResourceSetManifest? { nil }
    func commit(_ item: UploadItem, library: UUID) throws {
        throw ClientError.http(503, "Identity service unavailable.")
    }
    func refreshAuthorization() throws { throw ClientError.http(503, "Identity service unavailable.") }
}

private actor SignedOutUploadRemote: UploadRemote {
    func create(_ resource: UploadResource, item: UploadItem, library: UUID) throws -> UploadResourceStatus {
        throw ClientError.signedOut
    }
    func retry(_ resource: UploadResource, item: UploadItem, library: UUID) throws -> UploadResourceStatus {
        throw ClientError.signedOut
    }
    func complete(_ resource: UploadResource) throws -> UploadResourceStatus { throw ClientError.signedOut }
    func uploadRequest(_ resource: UploadResource, part: Int, policy: UploadPolicy) throws -> URLRequest {
        throw ClientError.signedOut
    }
    func manifest(_ item: UploadItem) -> UploadResourceSetManifest? { nil }
    func commit(_ item: UploadItem, library: UUID) throws { throw ClientError.signedOut }
    func refreshAuthorization() throws { throw ClientError.signedOut }
}

private actor FailingRefreshRemote: UploadRemote {
    private let base = UploadRemoteFake()
    func create(_ resource: UploadResource, item: UploadItem, library: UUID) async throws -> UploadResourceStatus {
        try await base.create(resource, item: item, library: library)
    }
    func retry(_ resource: UploadResource, item: UploadItem, library: UUID) async throws -> UploadResourceStatus {
        try await base.retry(resource, item: item, library: library)
    }
    func complete(_ resource: UploadResource) async throws -> UploadResourceStatus {
        try await base.complete(resource)
    }
    func uploadRequest(_ resource: UploadResource, part: Int, policy: UploadPolicy) async throws -> URLRequest {
        try await base.uploadRequest(resource, part: part, policy: policy)
    }
    func manifest(_ item: UploadItem) async -> UploadResourceSetManifest? { await base.manifest(item) }
    func commit(_ item: UploadItem, library: UUID) async throws { try await base.commit(item, library: library) }
    func refreshAuthorization() throws { throw URLError(.notConnectedToInternet) }
}
