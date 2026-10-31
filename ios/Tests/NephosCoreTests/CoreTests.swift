import XCTest

@testable import NephosCore

@MainActor
private final class QueryTestTokens: AccessTokenProviding {
    func accessToken() async throws -> String { "fixture-only" }
}

final class CoreTests: XCTestCase {
    func testSHA256AndPKCEVector() {
        XCTAssertEqual(
            Hashing.sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Hashing.sha256(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Hashing.base64URL(Data([0xfb, 0xff, 0x00])), "-_8A")
        XCTAssertEqual(
            Hashing.pkceChallenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
    func testChunkBoundariesAndCoverage() throws {
        for size in [Int64(1), 4_194_303, 4_194_304, 4_194_305, 8_589_934_592] {
            let count = Chunking.count(size: size, chunkSize: 4_194_304)
            let lengths = try (0..<count).map { try Chunking.length(index: $0, size: size, chunkSize: 4_194_304) }
            XCTAssertEqual(lengths.reduce(Int64(0)) { $0 + Int64($1) }, size)
            XCTAssertTrue(lengths.allSatisfy { $0 > 0 && $0 <= 4_194_304 })
            XCTAssertThrowsError(try Chunking.length(index: count, size: size, chunkSize: 4_194_304))
            XCTAssertThrowsError(try Chunking.length(index: -1, size: size, chunkSize: 4_194_304))
        }
        XCTAssertEqual(Chunking.count(size: 0, chunkSize: 4), 0)
    }
    func testURLTrustBoundaries() throws {
        XCTAssertEqual(try URLPolicy.validate("https://EXAMPLE.com/base/").absoluteString, "https://example.com/base")
        for value in [
            "http://example.com", "https://user:pass@example.com", "https://example.com?q=x", "file:///etc",
            "https://example.com/#x",
        ] {
            XCTAssertThrowsError(try URLPolicy.validate(value, allowDevelopmentHTTP: true))
        }
        XCTAssertThrowsError(try URLPolicy.validate("http://192.168.1.2"))
        XCTAssertNoThrow(try URLPolicy.validate("http://192.168.1.2:8080/base", allowDevelopmentHTTP: true))
        XCTAssertNoThrow(try URLPolicy.validate("http://localhost:8080", allowDevelopmentHTTP: true))
        XCTAssertThrowsError(try URLPolicy.validate("http://172.32.0.1", allowDevelopmentHTTP: true))
        XCTAssertThrowsError(try URLPolicy.validate("http://10.bad.0.0.1", allowDevelopmentHTTP: true))
        XCTAssertFalse(URLPolicy.sameOrigin(URL(string: "https://a.test")!, URL(string: "https://b.test")!))
        XCTAssertFalse(URLPolicy.sameOrigin(URL(string: "https://a.test")!, URL(string: "http://a.test")!))
        XCTAssertTrue(URLPolicy.sameOrigin(URL(string: "https://a.test")!, URL(string: "https://a.test:443/x")!))
    }
    func testSettingsAreIndependentAndDefaultOff() throws {
        var settings = BackupSettings()
        XCTAssertFalse(settings.automaticBackup)
        XCTAssertFalse(settings.automaticCleanup)
        XCTAssertFalse(settings.allowCellular)
        XCTAssertFalse(settings.cleanupWarningsAcknowledged)
        settings.automaticCleanup = true
        XCTAssertFalse(settings.automaticBackup)
        settings.automaticBackup = true
        settings.automaticCleanup = false
        XCTAssertTrue(settings.automaticBackup)
        XCTAssertEqual(try JSONDecoder().decode(BackupSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
    func testGalleryPagingDeduplicatesBoundsAndChecksLibrary() throws {
        let library = UUID()
        var window = GalleryWindow()
        var previous: Asset?
        for page in 0..<7 {
            var items = (0..<50).map { index in asset(library: library, date: "\(page)-\(index)") }
            if let previous { items.insert(previous, at: 0) }
            previous = items.last
            try window.append(
                AssetPage(items: items, nextCursor: GalleryCursor(createdAt: "\(page)", id: items.last!.id)),
                libraryID: library)
        }
        XCTAssertEqual(window.items.count, 300)
        XCTAssertEqual(Set(window.items.map(\.id)).count, 300)
        XCTAssertThrowsError(try window.append(AssetPage(items: [], nextCursor: window.nextCursor), libraryID: library))
        XCTAssertThrowsError(
            try window.append(AssetPage(items: [asset(library: UUID())], nextCursor: nil), libraryID: library))
        window.reset()
        XCTAssertTrue(window.items.isEmpty)
        XCTAssertFalse(window.hasLoaded)
    }
    func testPagingUsesExactBackendCursorContract() {
        let id = UUID()
        let date = "2026-10-25T21:00:00.123456Z"
        let libraryQuery = Paging.libraries(after: id)
        XCTAssertEqual(libraryQuery.map(\.name), ["limit", "after"])
        XCTAssertEqual(libraryQuery.last?.value, id.uuidString)
        let query = Paging.gallery(before: GalleryCursor(createdAt: date, id: id))
        XCTAssertEqual(query.map(\.name), ["limit", "before", "beforeId"])
        XCTAssertEqual(query[1].value, date)
        XCTAssertEqual(query[2].value, id.uuidString)
        XCTAssertEqual(Paging.gallery(before: nil).count, 1)
    }
    @MainActor
    func testOutgoingQueryPreservesPlusOffsetsAndLiteralValuesUnderFormDecoding() throws {
        let api = API(
            connection: Connection(
                baseURL: URL(string: "https://server.test/base")!,
                config: ServerConfig(
                    serverId: "fixture", issuer: "https://identity.test", clientId: "fixture",
                    maxUploadBytes: 10, chunkSize: 4), allowDevelopmentHTTP: false),
            auth: QueryTestTokens())
        let values = [
            "2025-08-31T06:04:59+00:00", "2025-08-31T06:04:59.123456+05:30",
            "2025-08-31T06:04:59-04:00", "2025-08-31T06:04:59Z",
            "name+alias %2B & = # \u{00e9}\u{0436}",
        ]
        for value in values {
            let url = try api.endpoint("assets", query: [URLQueryItem(name: "before", value: value)])
            let encoded = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
            XCTAssertFalse(encoded.contains("+"))
            let rawValue = String(try XCTUnwrap(encoded.split(separator: "=", maxSplits: 1).last))
            XCTAssertEqual(rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding, value)
        }
    }
    func testUploadIntentPreservesCaptureDateAndIdempotency() throws {
        var record = upload()
        record.capturedAt = "2020-02-01T12:30:00Z"
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(UploadIntent(record))) as? [String: Any])
        XCTAssertEqual(json["capturedAt"] as? String, record.capturedAt)
        XCTAssertEqual(json["id"] as? String, record.id.uuidString)
        XCTAssertEqual(json["sha256"] as? String, record.sha256)
        XCTAssertNil(json["source"])
        record.capturedAt = nil
        let missing = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(UploadIntent(record))) as? [String: Any])
        XCTAssertNil(missing["capturedAt"])
    }
    func testReconcileUsesServerPartsAndStableIdentity() throws {
        var record = upload()
        record.receivedParts = [0]
        try record.reconcile(
            UploadStatus(
                id: record.id, state: "uploading", chunkSize: 4, receivedParts: [1, 1], assetId: nil, error: nil),
            chunkSize: 4)
        XCTAssertEqual(record.receivedParts, [1])
        XCTAssertThrowsError(
            try record.reconcile(
                UploadStatus(
                    id: UUID(), state: "ready", chunkSize: 4, receivedParts: [], assetId: record.id, error: nil),
                chunkSize: 4))
        let canonical = UUID()
        try record.reconcile(
            UploadStatus(
                id: record.id, state: "ready", chunkSize: 4, receivedParts: [], assetId: canonical, error: nil),
            chunkSize: 4)
        XCTAssertEqual(record.committedAssetID, canonical)
        XCTAssertThrowsError(
            try record.reconcile(
                UploadStatus(id: record.id, state: "ready", chunkSize: 4, receivedParts: [], assetId: nil, error: nil),
                chunkSize: 4))
        XCTAssertThrowsError(
            try record.reconcile(
                UploadStatus(
                    id: record.id, state: "uploading", chunkSize: 4, receivedParts: [-1], assetId: nil, error: nil),
                chunkSize: 4))
        XCTAssertThrowsError(
            try record.reconcile(
                UploadStatus(
                    id: record.id, state: "unknown", chunkSize: 4, receivedParts: [], assetId: nil, error: nil),
                chunkSize: 4))
        try record.reconcile(
            UploadStatus(
                id: record.id, state: "ready", chunkSize: 4, receivedParts: [0, 1], assetId: record.id, error: nil),
            chunkSize: 4)
        XCTAssertEqual(record.phase, .ready)
    }
    func testRetryBackoffIsBoundedAndPreservesIdentity() {
        var record = upload()
        let id = record.id
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        record.deferRetry(now: now)
        XCTAssertEqual(record.nextRetryAt, now.addingTimeInterval(30))
        record.deferRetry(now: now)
        XCTAssertEqual(record.nextRetryAt, now.addingTimeInterval(60))
        for _ in 0..<30 { record.deferRetry(now: now) }
        XCTAssertEqual(record.nextRetryAt, now.addingTimeInterval(3600))
        XCTAssertEqual(record.id, id)
        record.phase = .sourceChanged
        XCTAssertFalse(record.needsTransfer)
        record.phase = .ready
        XCTAssertTrue(record.needsTransfer)
        record.evidence = BackupEvidence(
            id: id, sha256: record.sha256, size: record.size, available: true, createdAt: "")
        XCTAssertFalse(record.needsTransfer)
    }
    func testCleanupRequiresFreshExactEvidenceAndHold() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var record = upload()
        record.phase = .ready
        record.evidence = BackupEvidence(
            id: record.id, sha256: record.sha256, size: record.size, available: true, createdAt: "")
        record.evidenceCheckedAt = now
        XCTAssertNotNil(record.cleanupBlock(current: record.source, now: now))
        record.retention = hold(record: record, until: now.addingTimeInterval(86_400))
        XCTAssertNil(record.cleanupBlock(current: record.source, now: now))
        XCTAssertNotNil(record.cleanupBlock(current: nil, now: now))
        XCTAssertNotNil(record.cleanupBlock(current: record.source, now: now.addingTimeInterval(61)))
        XCTAssertNotNil(record.cleanupBlock(current: record.source, now: now.addingTimeInterval(-1)))
        record.retention = hold(record: record, until: now.addingTimeInterval(1800))
        XCTAssertNotNil(record.cleanupBlock(current: record.source, now: now))
        record.retention = hold(record: record, until: now.addingTimeInterval(86_400), assurance: "unknown")
        XCTAssertNotNil(record.cleanupBlock(current: record.source, now: now))
        record.retention = hold(record: record, until: now.addingTimeInterval(86_400))
        record.evidence = BackupEvidence(
            id: record.id, sha256: "wrong", size: record.size, available: true, createdAt: "")
        XCTAssertNotNil(record.cleanupBlock(current: record.source, now: now))
        var compound = upload(supported: false)
        compound.phase = .ready
        compound.evidence = BackupEvidence(
            id: compound.id, sha256: compound.sha256, size: compound.size, available: true, createdAt: "")
        compound.evidenceCheckedAt = now
        compound.retention = hold(record: compound, until: now.addingTimeInterval(86_400))
        XCTAssertNotNil(compound.cleanupBlock(current: compound.source, now: now))
    }
    func testFileHashAndLedgerPersistenceIsolation() throws {
        let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
            ".test-work"
        ).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try LedgerStore(root: workspace)
        let account = String(repeating: "a", count: 64)
        let other = String(repeating: "b", count: 64)
        var ledger = AccountLedger()
        ledger.settings.automaticCleanup = true
        ledger.records = [upload()]
        let record = ledger.records[0]
        let file = try store.staging(account: account, id: record.id)
        try Data(repeating: 97, count: 1_000_000).write(to: file)
        let hash = try Hashing.file(file)
        XCTAssertEqual(hash.size, 1_000_000)
        XCTAssertEqual(hash.sha256, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        try store.save(ledger, account: account)
        let restored = try store.load(account: account)
        XCTAssertEqual(restored.records, ledger.records)
        XCTAssertTrue(restored.settings.automaticCleanup)
        XCTAssertFalse(restored.settings.automaticBackup)
        XCTAssertTrue(try store.load(account: other).records.isEmpty)
        XCTAssertThrowsError(try store.accountDirectory("../outside"))
        try Data("corrupted".utf8).write(to: store.accountDirectory(account).appendingPathComponent("ledger.json"))
        XCTAssertThrowsError(try store.load(account: account))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testAccountKeyIncludesEveryTrustBoundary() {
        let config = ServerConfig(
            serverId: "one", issuer: "https://identity.test", clientId: "nephos-ios", maxUploadBytes: 10, chunkSize: 4)
        let connection = Connection(
            baseURL: URL(string: "https://server.test/base")!, config: config, allowDevelopmentHTTP: false)
        let key = LedgerStore.accountKey(connection: connection, subject: "alice")
        XCTAssertNotEqual(key, LedgerStore.accountKey(connection: connection, subject: "bob"))
        let changed = Connection(
            baseURL: URL(string: "https://other.test/base")!, config: config, allowDevelopmentHTTP: false)
        XCTAssertNotEqual(key, LedgerStore.accountKey(connection: changed, subject: "alice"))
        XCTAssertEqual(key.count, 64)
    }
    private func asset(library: UUID, date: String = "2026-01-01T00:00:00Z") -> Asset {
        Asset(
            id: UUID(), libraryId: library, fileName: "photo.jpg", mediaType: "image/jpeg", size: 8,
            sha256: String(repeating: "a", count: 64), createdAt: date, hasPreview: false)
    }
    private func upload(supported: Bool = true) -> UploadRecord {
        UploadRecord(
            id: UUID(), libraryId: UUID(), fileName: "photo.jpg", mediaType: "image/jpeg", size: 8,
            sha256: String(repeating: "a", count: 64),
            source: SourceRevision(
                localIdentifier: "local-id", modificationTime: 10, resourceNames: ["photo.jpg"],
                resourceTypes: [1], pixelWidth: 10, pixelHeight: 10, duration: 0, cleanupSupported: supported),
            resourceIndex: 0)
    }
    private func hold(record: UploadRecord, until: Date, assurance: String = "single-volume-no-independent-backup")
        -> RetentionHold
    {
        RetentionHold(
            id: record.id, sha256: record.sha256, size: record.size, available: true, holdId: UUID(),
            retainedUntil: ISO8601DateFormatter().string(from: until), assurance: assurance)
    }
}
