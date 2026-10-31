import Foundation
import XCTest

@testable import NephosCore

@MainActor
private final class FixtureTokens: AccessTokenProviding {
    private let bearer: String
    init(_ bearer: String) { self.bearer = bearer }
    func accessToken() async throws -> String { bearer }
}

final class NativeBackendTests: XCTestCase {
    @MainActor
    func testRealBackendUploadResumeGalleryOriginalAndRetention() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NEPHOS_NATIVE_E2E"] == "1" else {
            throw XCTSkip(
                "Opt-in real-backend test. Run python3 run_native_e2e.py --backend-stable after the stack is stable.")
        }
        guard let bearer = environment["NEPHOS_E2E_BEARER"], !bearer.isEmpty,
            let subject = environment["NEPHOS_E2E_SUBJECT"], !subject.isEmpty,
            let libraryID = environment["NEPHOS_E2E_LIBRARY"].flatMap(UUID.init(uuidString:)),
            let uploadID = environment["NEPHOS_E2E_UPLOAD"].flatMap(UUID.init(uuidString:)),
            let rootPath = environment["NEPHOS_E2E_WORKSPACE"],
            let server = environment["NEPHOS_E2E_SERVER"]
        else { throw ClientError.invalid("The disposable native E2E fixture environment is incomplete.") }
        let base = try URLPolicy.validate(server, allowDevelopmentHTTP: true)
        guard base.host == "localhost", base.port == 18080 else {
            throw ClientError.invalid("This destructive-fixture test only runs against the local development backend.")
        }
        let config = try await HTTP.json(ServerConfig.self, HTTP.request(base.appendingPathComponent("v1/config")))
        XCTAssertEqual(config.clientId, "nephos-ios")
        XCTAssertEqual(config.chunkSize, 4_194_304)
        XCTAssertFalse(config.serverId.isEmpty)
        let connection = Connection(baseURL: base, config: config, allowDevelopmentHTTP: true)
        let api = API(connection: connection, auth: FixtureTokens(bearer))
        let client = UploadClient(api: api)
        let libraries = try await api.libraries()
        XCTAssertTrue(libraries.items.contains { $0.id == libraryID })
        let emptySnapshot = try await api.snapshot(library: libraryID)
        XCTAssertEqual(emptySnapshot.totalCount, 0)
        print("PASS native XCTest: production Swift config and authorized library client")

        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let store = try LedgerStore(root: root)
        let account = LedgerStore.accountKey(connection: connection, subject: subject)
        let original = try store.staging(account: account, id: uploadID)
        let bytes = Data((0..<(2 * config.chunkSize + 17)).map { UInt8(truncatingIfNeeded: ($0 * 31) ^ ($0 >> 9)) })
        try bytes.write(to: original, options: .atomic)
        let hash = try Hashing.file(original)
        var record = UploadRecord(
            id: uploadID, libraryId: libraryID, fileName: "native-fixture.bin",
            mediaType: "application/octet-stream", size: hash.size, sha256: hash.sha256,
            source: SourceRevision(
                localIdentifier: "synthetic-native-fixture", modificationTime: 1,
                resourceNames: ["native-fixture.bin"], resourceTypes: [1], pixelWidth: 0, pixelHeight: 0,
                duration: 0, cleanupSupported: false), resourceIndex: 0)
        record.capturedAt = "2018-02-03T12:00:00Z"
        let initial = try await client.begin(record)
        try record.reconcile(initial, chunkSize: config.chunkSize)
        XCTAssertEqual(record.id, uploadID)
        XCTAssertEqual(record.phase, .uploading)
        let repeated = try await client.begin(record)
        XCTAssertEqual(repeated.id, uploadID)

        var parts: [URL] = []
        for part in 0..<Chunking.count(size: record.size, chunkSize: config.chunkSize) {
            let length = try Chunking.length(index: part, size: record.size, chunkSize: config.chunkSize)
            let lower = part * config.chunkSize
            let file = try store.chunk(account: account, id: uploadID, part: part)
            try bytes.subdata(in: lower..<(lower + length)).write(to: file, options: .atomic)
            parts.append(file)
        }
        try await client.sendPart(record, index: 1, file: parts[1], using: UploadClient.foregroundPart)
        try await client.sendPart(record, index: 1, file: parts[1], using: UploadClient.foregroundPart)

        // Reconstruct the client and record from disk, not from the in-memory acknowledgement.
        var ledger = AccountLedger()
        ledger.records = [record]
        try store.save(ledger, account: account)
        record = try XCTUnwrap(store.load(account: account).records.first)
        let resumedClient = UploadClient(api: API(connection: connection, auth: FixtureTokens(bearer)))
        let resumed = try await resumedClient.status(uploadID)
        try record.reconcile(resumed, chunkSize: config.chunkSize)
        XCTAssertEqual(record.receivedParts, [1])
        for part in [2, 0] {
            try await resumedClient.sendPart(record, index: part, file: parts[part], using: UploadClient.foregroundPart)
        }
        let completed = try await resumedClient.complete(uploadID)
        try record.reconcile(completed, chunkSize: config.chunkSize)
        let deadline = Date().addingTimeInterval(120)
        while record.phase != .ready && Date() < deadline {
            if record.phase == .failed {
                throw ClientError.invalid("The server rejected the synthetic original during verification.")
            }
            try await Task.sleep(for: .seconds(1))
            let status = try await resumedClient.status(uploadID)
            try record.reconcile(status, chunkSize: config.chunkSize)
        }
        XCTAssertEqual(record.phase, .ready, "Server verification/projection did not commit within 120 seconds.")
        guard record.phase == .ready else { return }
        XCTAssertEqual(record.assetId, uploadID)
        print(
            "PASS native XCTest: immutable intent, file-backed parts, out-of-order duplicate part, disk-ledger resume and ready polling"
        )

        let gallery = try await api.assets(library: libraryID, cursor: nil)
        let committed = try XCTUnwrap(gallery.items.first { $0.id == uploadID })
        XCTAssertEqual(committed.libraryId, libraryID)
        XCTAssertEqual(committed.sha256, hash.sha256)
        XCTAssertEqual(committed.size, hash.size)
        XCTAssertTrue(committed.createdAt.hasPrefix("2018-02-03T12:00:00"))
        let fetched = try await HTTP.data(resumedClient.originalRequest(uploadID), maximum: bytes.count + 1)
        XCTAssertEqual(fetched.count, bytes.count)
        XCTAssertTrue(fetched == bytes, "Downloaded original differs from the exact synthetic input bytes.")
        XCTAssertEqual(Hashing.sha256(fetched), hash.sha256)
        let evidence = try await resumedClient.evidence(uploadID)
        XCTAssertEqual(evidence.id, uploadID)
        XCTAssertEqual(evidence.sha256, hash.sha256)
        XCTAssertEqual(evidence.size, hash.size)
        XCTAssertTrue(evidence.available)
        print("PASS native XCTest: capture-date gallery, exact original bytes and authoritative backup evidence")
        let range = try await MediaRange.fetch(committed, offset: Int64(config.chunkSize - 7), length: 31, api: api)
        XCTAssertEqual(range, bytes.subdata(in: (config.chunkSize - 7)..<(config.chunkSize + 24)))
        let firstSnapshot = try await api.snapshot(library: libraryID)
        XCTAssertGreaterThan(firstSnapshot.revision, emptySnapshot.revision)
        let stillEmpty = try await api.assets(library: libraryID, snapshot: emptySnapshot.id, cursor: nil)
        XCTAssertTrue(stillEmpty.items.isEmpty, "A retained snapshot must not acquire later uploads.")
        let years = try await api.timeline(library: libraryID, snapshot: firstSnapshot.id)
        XCTAssertTrue(years.contains { $0.date.hasPrefix("2018") && $0.count == 1 })
        let days = try await api.timeline(library: libraryID, snapshot: firstSnapshot.id, year: 2018, month: 2)
        XCTAssertTrue(days.contains { $0.date == "2018-02-03" && $0.count == 1 })
        let dayPage = try await api.assets(
            library: libraryID, snapshot: firstSnapshot.id, cursor: GalleryDates.endOfBucket("2018-02-03"))
        XCTAssertEqual(dayPage.items.first?.id, committed.id)
        for path in [
            "v1/libraries/\(libraryID)/assets",
            "v1/libraries/\(libraryID)/snapshots/\(firstSnapshot.id)/assets",
        ] {
            let page = try await api.json(
                AssetPage.self, path,
                query: Paging.gallery(
                    before: GalleryCursor(
                        createdAt: "2018-02-04T00:00:00+00:00", id: UUID())))
            XCTAssertEqual(page.items.first?.id, committed.id)
        }
        let anchored = try await api.assets(
            library: libraryID, snapshot: firstSnapshot.id,
            cursor: GalleryDates.inclusiveAnchor(
                GalleryCursor(
                    createdAt: "2018-02-03T12:00:00+00:00", id: committed.id)))
        XCTAssertEqual(anchored.items.first?.id, committed.id)
        print(
            "PASS native XCTest: bounded authenticated range, immutable snapshots, year/day counts and exact-date navigation"
        )

        do {
            let hold = try await resumedClient.retain(uploadID)
            XCTAssertTrue(hold.allowsRemoval(id: uploadID, sha256: hash.sha256, size: hash.size, now: Date()))
            record.evidence = evidence
            record.evidenceCheckedAt = Date()
            record.retention = hold
            XCTAssertNotNil(
                record.cleanupBlock(current: record.source),
                "Synthetic/unsupported source must remain blocked even with a real retention hold.")
            print(
                "PASS native XCTest: persisted server retention assurance matches verified original; no Photos deletion performed"
            )
        } catch ClientError.http(404, _) {
            guard environment["NEPHOS_E2E_REQUIRE_RETENTION"] != "1" else {
                throw ClientError.invalid("This backend profile requires retention, but the endpoint returned 404.")
            }
            print("NOTE native XCTest: retention endpoint not exposed by this backend profile")
        }
        guard
            let extra = environment["NEPHOS_E2E_RESOURCE_UPLOADS"]?.split(separator: ",").compactMap({
                UUID(uuidString: String($0))
            }),
            extra.count == 8
        else { throw ClientError.invalid("Eight pre-registered resource upload IDs are required.") }
        var published: [ResourceManifest] = []
        var nextResource = 0
        for setIndex in 0..<3 {
            let edited = setIndex == 2
            let roles = edited ? ["photo", "adjustmentData", "unknown-16", "fullSizePhoto"] : ["photo", "pairedVideo"]
            let source = SourceRevision(
                localIdentifier: "synthetic-pair-\(setIndex)", modificationTime: 123,
                resourceNames: roles.map { "\($0).bin" }, resourceTypes: edited ? [1, 7, 16, 5] : [1, 9], pixelWidth: 0,
                pixelHeight: 0,
                duration: 0, cleanupSupported: false, creationTime: 100,
                resourceUTIs: edited
                    ? [
                        "public.heic", "com.apple.property-list", "com.apple.photos.apple-adjustment-envelope",
                        "public.heic",
                    ]
                    : ["public.jpeg", "com.apple.quicktime-movie"])
            let group = ResourceSetRecord(
                id: UUID(), libraryId: libraryID, source: source, kind: edited ? "edited" : "live-photo")
            var resources: [UploadRecord] = []
            for resourceIndex in roles.indices {
                let id = extra[nextResource]
                nextResource += 1
                // Repeated bytes in the second set exercise safe same-subject dedup with separate logical references.
                let data = Data("native-compound-resource-\(resourceIndex)".utf8)
                let file = try store.staging(account: account, id: id)
                try data.write(to: file)
                var part = UploadRecord(
                    id: id, libraryId: libraryID, fileName: source.resourceNames[resourceIndex],
                    mediaType: "application/octet-stream", size: Int64(data.count), sha256: Hashing.sha256(data),
                    source: source, resourceIndex: resourceIndex)
                part.resourceSetId = group.id
                part.resourceRole = roles[resourceIndex]
                part.uniformTypeIdentifier = source.resourceUTIs![resourceIndex]
                part.capturedAt = "2020-05-06T12:00:00Z"
                let begun = try await client.begin(part)
                try part.reconcile(begun, chunkSize: config.chunkSize)
                if part.phase == .uploading {
                    try await client.sendPart(part, index: 0, file: file, using: UploadClient.foregroundPart)
                    let completion = try await client.complete(part.id)
                    try part.reconcile(completion, chunkSize: config.chunkSize)
                }
                let limit = Date().addingTimeInterval(60)
                while part.phase == .verifying && Date() < limit {
                    try await Task.sleep(for: .seconds(1))
                    let status = try await client.status(part.id)
                    try part.reconcile(status, chunkSize: config.chunkSize)
                }
                XCTAssertEqual(part.phase, .ready)
                part.evidence = try await client.evidence(part.committedAssetID)
                resources.append(part)
                let pendingSnapshot = try await api.snapshot(library: libraryID)
                let pendingGallery = try await api.assets(library: libraryID, snapshot: pendingSnapshot.id, cursor: nil)
                XCTAssertFalse(
                    pendingGallery.items.contains { $0.id == part.committedAssetID },
                    "An unpublished constituent must stay out of the gallery.")
            }
            let manifest = try await api.publish(group, records: resources)
            let repeatedManifest = try await api.publish(group, records: resources)
            XCTAssertEqual(manifest, repeatedManifest)
            XCTAssertEqual(manifest.resources.count, roles.count)
            XCTAssertEqual(manifest.resources.map(\.role), roles)
            if edited { XCTAssertFalse(manifest.restoreSupported) }
            if let prior = published.first {
                XCTAssertTrue(
                    Set(prior.resources.map(\.assetId)).isDisjoint(with: Set(manifest.resources.map(\.assetId))))
            }
            published.append(manifest)
            let hold = try await api.retain(manifest)
            XCTAssertTrue(hold.validates(manifest))
            let current = try await api.snapshot(library: libraryID)
            let page = try await api.assets(library: libraryID, snapshot: current.id, cursor: nil)
            let primary = try XCTUnwrap(page.items.first { $0.id == manifest.primaryAssetId })
            XCTAssertEqual(primary.resourceSetId, manifest.id)
            XCTAssertFalse(page.items.contains { $0.id == resources[1].committedAssetID })
            let fetchedManifest = try await api.resources(primary)
            XCTAssertEqual(fetchedManifest, manifest)
            for part in manifest.resources {
                let original = try await HTTP.data(client.originalRequest(part.assetId), maximum: 1024)
                XCTAssertEqual(Hashing.sha256(original), part.sha256)
                XCTAssertEqual(Int64(original.count), part.size)
            }
        }
        let finalSnapshot = try await api.snapshot(library: libraryID)
        var revision = emptySnapshot.revision
        var found: Set<UUID> = []
        while revision < finalSnapshot.revision {
            let delta = try await api.changes(library: libraryID, after: revision, through: finalSnapshot.revision)
            found.formUnion(delta.changes.flatMap(\.items).filter { $0.operation == "upsert" }.map(\.assetId))
            revision = delta.toRevision
        }
        XCTAssertTrue(found.contains(committed.id))
        XCTAssertTrue(published.allSatisfy { found.contains($0.primaryAssetId) })
        let finalPage = try await api.assets(library: libraryID, snapshot: finalSnapshot.id, cursor: nil)
        var window = GalleryWindow()
        try window.append(finalPage, libraryID: libraryID)
        let retained = RetainedGallery(
            library: Library(id: libraryID, name: "Fixture"), snapshot: finalSnapshot,
            window: window, anchor: nil, updatedAt: Date())
        try store.saveGallery(retained, account: account)
        XCTAssertEqual(try store.loadGallery(account: account, library: libraryID)?.snapshot.revision, revision)
        let frozenFirst = try await api.assets(library: libraryID, snapshot: firstSnapshot.id, cursor: nil)
        XCTAssertEqual(frozenFirst.items.map(\.id), [committed.id])
        print(
            "PASS native XCTest: hidden partial sets, atomic complete publication, canonical dedup references, full-resource retrieval/retention, delta catch-up and disk snapshot restore"
        )
        guard let previewID = environment["NEPHOS_E2E_PREVIEW_UPLOAD"].flatMap(UUID.init(uuidString:)),
            let previewPath = environment["NEPHOS_E2E_PREVIEW_FILE"]
        else { throw ClientError.invalid("Missing registered native preview fixture.") }
        let previewFile = URL(fileURLWithPath: previewPath)
        let previewHash = try Hashing.file(previewFile)
        var photo = UploadRecord(
            id: previewID, libraryId: libraryID, fileName: "preview-fixture.png", mediaType: "image/png",
            size: previewHash.size, sha256: previewHash.sha256,
            source: SourceRevision(
                localIdentifier: "native-preview-fixture", modificationTime: 1,
                resourceNames: ["preview-fixture.png"], resourceTypes: [1],
                pixelWidth: 2, pixelHeight: 2, duration: 0, cleanupSupported: false),
            resourceIndex: 0)
        let photoIntent = try await client.begin(photo)
        try photo.reconcile(photoIntent, chunkSize: config.chunkSize)
        try await client.sendPart(photo, index: 0, file: previewFile, using: UploadClient.foregroundPart)
        let photoComplete = try await client.complete(photo.id)
        try photo.reconcile(photoComplete, chunkSize: config.chunkSize)
        let photoDeadline = Date().addingTimeInterval(60)
        while photo.phase == .verifying && Date() < photoDeadline {
            try await Task.sleep(for: .seconds(1))
            let status = try await client.status(photo.id)
            try photo.reconcile(status, chunkSize: config.chunkSize)
        }
        XCTAssertEqual(photo.phase, .ready)
        for size in PreviewSize.allCases {
            let request = try await api.previewRequest(photo.committedAssetID, size: size)
            let bytes = try await HTTP.data(request, maximum: 8 * 1024 * 1024, session: api.session)
            XCTAssertEqual(Array(bytes.prefix(2)), [0xff, 0xd8])
            XCTAssertNotEqual(Hashing.sha256(bytes), previewHash.sha256)
        }
        let untouched = try await HTTP.data(client.originalRequest(photo.committedAssetID), maximum: 1024)
        XCTAssertEqual(Hashing.sha256(untouched), previewHash.sha256)
        print(
            "PASS native XCTest: all three authenticated JPEG preview sizes; explicit original export remains byte-exact"
        )
    }
}
