#if DEBUG
    import Foundation

    extension UploadCandidate {
        static func fixture(id: String = "fixture-photo", live: Bool = false) -> UploadCandidate {
            var resources = [
                UploadResourceDescriptor(
                    type: 1, role: "photo", filename: "\(id).HEIC", uniformTypeIdentifier: "public.heic",
                    mediaType: "image/heic", isPrimary: true)
            ]
            if live {
                resources.append(
                    UploadResourceDescriptor(
                        type: 9, role: "pairedVideo", filename: "\(id).MOV",
                        uniformTypeIdentifier: "com.apple.quicktime-movie", mediaType: "video/quicktime",
                        isPrimary: false))
            }
            return UploadCandidate(
                localIdentifier: id, sourceRevision: "fixture-revision", kind: live ? "live-photo" : "single",
                capturedAt: nil, resources: resources)
        }
    }

    extension UploadDestination {
        static func fixture() throws -> UploadDestination {
            let origin = try URLPolicy.validate("https://backup.example.test:8443")
            return UploadDestination(
                connection: Connection(
                    baseURL: origin,
                    config: ServerConfig(
                        serverId: "fixture-server",
                        issuer: origin.appendingPathComponent("realms/nephos").absoluteString,
                        clientId: "nephos-ios", maxUploadBytes: UploadChunk.maximumBytes,
                        chunkSize: UploadChunk.byteCount),
                    allowDevelopmentHTTP: false),
                subject: "fixture-owner",
                installationID: UploadIdentity.id(["fixture-installation"]),
                libraryID: UploadIdentity.id(["fixture-library"]), libraryName: "Fixture library")
        }
    }

    actor UploadSessionStorageFake: SessionStorage {
        private var value: EnrollmentVault
        init(destination: UploadDestination) {
            var vault = EnrollmentVault()
            vault.save(
                Credentials(
                    connection: destination.connection, subject: destination.subject, nonce: "fixture-nonce",
                    accessToken: "fixture-only-access", refreshToken: nil,
                    expiresAt: Date(timeIntervalSince1970: 2_000_000_000)))
            value = vault
        }
        func vault() -> EnrollmentVault { value }
        @discardableResult
        func update(_ change: @Sendable (inout EnrollmentVault) throws -> Void) throws -> EnrollmentVault {
            try change(&value)
            return value
        }
        func remove() { value = EnrollmentVault() }
    }

    actor UploadPhotoSourceFake: UploadPhotoSource {
        private let candidates: [UploadCandidate]
        init(_ candidates: [UploadCandidate]) { self.candidates = candidates }
        func discover(repository: any UploadRepository, scope: String) async throws {
            try await repository.finishDiscovery(candidates, checkpoint: nil, scope: scope)
        }
        func export(item: UploadItem, resource: UploadResource, to file: URL) throws {
            try Data(
                repeating: resource.descriptor.isPrimary ? 1 : 2,
                count: resource.descriptor.isPrimary ? 4 : 16
            ).write(to: file)
        }
    }

    actor UploadRemoteFake: UploadRemote {
        private struct Resource {
            let size: Int64
            var state = "uploading"
            var parts: Set<Int> = []
        }
        private var resources: [UUID: Resource] = [:]
        private(set) var committed: UploadResourceSetManifest?
        func create(_ resource: UploadResource, item: UploadItem, library: UUID) throws -> UploadResourceStatus {
            guard let size = resource.expectedBytes else { throw ClientError.invalid("Missing fixture size.") }
            if resources[resource.id] == nil { resources[resource.id] = Resource(size: size) }
            return try status(resource.id)
        }
        func retry(_ resource: UploadResource, item: UploadItem, library: UUID) throws -> UploadResourceStatus {
            try create(resource, item: item, library: library)
        }
        func complete(_ resource: UploadResource) throws -> UploadResourceStatus {
            guard let stored = resources[resource.id],
                stored.parts.count == UploadChunk.count(size: stored.size)
            else { throw ClientError.invalid("Fixture chunks are incomplete.") }
            resources[resource.id]?.state = "verifying"
            return try status(resource.id)
        }
        func uploadRequest(_ resource: UploadResource, part: Int, policy: UploadPolicy) throws -> URLRequest {
            HTTP.request(
                try URLPolicy.validate("https://backup.example.test:8443/v1/uploads/\(resource.id)/parts/\(part)"),
                method: "PUT")
        }
        func manifest(_ item: UploadItem) -> UploadResourceSetManifest? { committed }
        func commit(_ item: UploadItem, library: UUID) throws {
            guard item.resources.allSatisfy({ resources[$0.id]?.state == "ready" }) else {
                throw ClientError.invalid("Fixture originals are not verified.")
            }
            committed = try UploadResourceSetManifest.input(item)
        }
        func refreshAuthorization() {}
        func accept(_ transfer: UploadTransfer) { resources[transfer.resourceID]?.parts.insert(transfer.part) }
        func verifyAll() {
            for id in resources.keys where resources[id]?.state == "verifying" { resources[id]?.state = "ready" }
        }
        private func status(_ id: UUID) throws -> UploadResourceStatus {
            guard let resource = resources[id] else { throw ClientError.invalid("Fixture resource missing.") }
            return UploadResourceStatus(
                id: id, state: resource.state, chunkSize: UploadChunk.byteCount,
                receivedParts: resource.parts.sorted(), assetId: resource.state == "ready" ? id : nil, error: nil)
        }
    }

    actor UploadTransportFake: UploadTransport {
        private var transfers: [UUID: UploadTransfer] = [:]
        func active() -> [UploadTransfer] { Array(transfers.values) }
        func enqueue(_ transfer: UploadTransfer, request: URLRequest, file: URL) throws {
            guard try Data(contentsOf: file).count == transfer.bytes else {
                throw ClientError.invalid("Fixture upload file has the wrong length.")
            }
            transfers[transfer.id] = transfer
        }
        func cancel(scope: String?) {
            transfers = transfers.filter { scope != nil && $0.value.scope != scope }
        }
        func finish(_ transfer: UploadTransfer) { transfers.removeValue(forKey: transfer.id) }
    }
#endif
