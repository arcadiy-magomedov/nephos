import Foundation
import XCTest

@testable import NephosCore

@MainActor
final class PersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".persistence-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testBootstrapWithoutCredentialsAndInstallationMarker() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = AccountPersistence(root: root)
        let first = try await worker.bootstrap()
        XCTAssertNil(first.connection)
        XCTAssertTrue(first.newInstallation)
        try await worker.markInstallation()
        let second = try await worker.bootstrap()
        XCTAssertFalse(second.newInstallation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Viewer").path))
    }

    func testNewerLedgerCannotBeOverwrittenByAnOlderSnapshot() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = String(repeating: "a", count: 64)
        let worker = AccountPersistence(root: root)
        var newest = AccountLedger()
        newest.scanAfter = "latest"
        try await worker.save(newest, account: account, revision: 2)
        try await worker.save(AccountLedger(), account: account, revision: 1)
        let restarted = try LedgerStore(root: root.appendingPathComponent("Accounts")).load(account: account)
        XCTAssertEqual(restarted.scanAfter, "latest")
    }

    func testConnectionClearCannotBeUndoneByAnOlderApproval() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = AccountPersistence(root: root)
        let connection = Connection(
            baseURL: URL(string: "https://photos.example.net")!,
            config: ServerConfig(
                serverId: "fixture", issuer: "https://photos.example.net/identity",
                clientId: "nephos-ios", maxUploadBytes: 100, chunkSize: 4_194_304),
            allowDevelopmentHTTP: false)
        try await worker.saveConnection(connection, revision: 1)
        try await worker.saveConnection(nil, revision: 3)
        try await worker.saveConnection(connection, revision: 2)
        let cleared = try await worker.bootstrap()
        XCTAssertNil(cleared.connection)
        try await worker.saveConnection(connection, revision: 4)
        let restored = try await worker.bootstrap()
        XCTAssertEqual(restored.connection, connection)
    }

    func testDelayedViewerResetCannotRemoveNewerGenerationFiles() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = AccountPersistence(root: root)
        _ = try await worker.bootstrap()
        try await worker.resetViewer(revision: 2)
        let file = root.appendingPathComponent("Viewer/current")
        try Data("current".utf8).write(to: file)
        try await worker.resetViewer(revision: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try await worker.resetViewer(revision: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testConcurrentSnapshotsPreserveHighestRevisionAndAccountIsolation() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = String(repeating: "a", count: 64)
        let other = String(repeating: "b", count: 64)
        let worker = AccountPersistence(root: root)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for revision in 1...40 {
                var ledger = AccountLedger()
                ledger.scanAfter = String(revision)
                let snapshot = ledger
                group.addTask {
                    try await worker.save(snapshot, account: account, revision: UInt64(revision))
                }
            }
            try await group.waitForAll()
        }
        try await worker.save(AccountLedger(), account: other, revision: 1)
        let store = try LedgerStore(root: root.appendingPathComponent("Accounts"))
        XCTAssertEqual(try store.load(account: account).scanAfter, "40")
        XCTAssertNil(try store.load(account: other).scanAfter)
    }

    func testFailedWritePropagatesAndSameRevisionCanRetry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = String(repeating: "a", count: 64)
        let store = try LedgerStore(root: root.appendingPathComponent("Accounts"))
        let file = try store.accountDirectory(account).appendingPathComponent("ledger.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let worker = AccountPersistence(root: root)
        var ledger = AccountLedger()
        ledger.scanAfter = "retry"
        do {
            try await worker.save(ledger, account: account, revision: 1)
            XCTFail("Writing over a directory must fail.")
        } catch {}
        try FileManager.default.removeItem(at: file)
        try await worker.save(ledger, account: account, revision: 1)
        XCTAssertEqual(try store.load(account: account).scanAfter, "retry")
    }

    func testGalleryClearFencesDelayedAnchorWriteAndNewerCacheCanFollow() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = String(repeating: "a", count: 64)
        let worker = AccountPersistence(root: root)
        let library = Library(id: UUID(), name: "Fixture")
        let snapshot = GallerySnapshot(
            id: UUID(), revision: 1, accessGeneration: 1,
            expiresAt: "2027-01-01T00:00:00Z", totalCount: 0)
        let cache = RetainedGallery(
            library: library, snapshot: snapshot, window: GalleryWindow(), anchor: nil, updatedAt: Date())
        try await worker.saveGallery(cache, account: account, revision: 1)
        try await worker.saveGallery(nil, account: account, revision: 3)
        try await worker.saveGallery(cache, account: account, revision: 2)
        let cleared = try await worker.loadGallery(account: account, library: library.id)
        XCTAssertNil(cleared)
        try await worker.saveGallery(cache, account: account, revision: 4)
        let restored = try await worker.loadGallery(account: account, library: library.id)
        XCTAssertEqual(restored?.snapshot.id, snapshot.id)
    }

    func testUnsupportedLedgerIsPreservedAndErrorIsPropagated() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = String(repeating: "a", count: 64)
        let store = try LedgerStore(root: root.appendingPathComponent("Accounts"))
        var ledger = AccountLedger()
        ledger.version = 99
        try store.save(ledger, account: account)
        let file = try store.accountDirectory(account).appendingPathComponent("ledger.json")
        let bytes = try Data(contentsOf: file)
        do {
            _ = try await AccountPersistence(root: root).load(account: account, offline: true)
            XCTFail("An unsupported ledger must not be replaced.")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}
