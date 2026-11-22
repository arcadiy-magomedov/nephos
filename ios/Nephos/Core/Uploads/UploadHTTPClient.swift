import Foundation

actor UploadHTTPClient: UploadRemote {
    private struct ResourceIntent: Encodable {
        let id: UUID
        let libraryId: UUID
        let resourceSetId: UUID
        let fileName: String
        let mediaType: String
        let size: Int64
        let sha256: String
        let capturedAt: Date?
    }
    private struct Libraries: Decodable {
        let items: [UploadLibrary]
        let nextCursor: UUID?
    }
    private struct Problem: Decodable {
        let title: String?
        let detail: String?
    }
    private struct Backup: Decodable {
        let id: UUID
        let sha256: String
        let size: Int64
        let available: Bool
    }
    private let connection: Connection
    private let authorization: UploadAuthorization
    private let session: URLSession

    init(
        connection: Connection, authorization: UploadAuthorization, session: URLSession = HTTP.makeSession()
    ) {
        self.connection = connection
        self.authorization = authorization
        self.session = session
    }

    func libraries() async throws -> [UploadLibrary] {
        var result: [UploadLibrary] = []
        var cursor: UUID?
        var cursors: Set<UUID> = []
        repeat {
            let suffix = cursor.map { "&after=\($0.uuidString)" } ?? ""
            let page: Libraries = try await decode("v1/libraries?limit=100\(suffix)")
            for library in page.items {
                do {
                    _ = try await send("v1/libraries/\(library.id.uuidString)?upload=true")
                    result.append(library)
                } catch let error as UploadFailure where error.status == 403 || error.status == 404 {
                    continue
                }

            }
            cursor = page.nextCursor
            if let cursor, !cursors.insert(cursor).inserted {
                throw ClientError.invalid("The server repeated a library pagination cursor.")
            }
        } while cursor != nil
        return result
    }

    func refreshAuthorization() async throws {
        _ = try await authorization.credentials(forceRefresh: true)
    }

    func create(_ resource: UploadResource, item: UploadItem, library: UUID) async throws -> UploadResourceStatus {
        guard let size = resource.expectedBytes, size > 0, let hash = resource.sha256, hash.count == 64 else {
            throw ClientError.invalid("Prepare and hash the original before requesting an upload.")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let input = ResourceIntent(
            id: resource.id, libraryId: library, resourceSetId: item.resourceSetID,
            fileName: resource.descriptor.filename, mediaType: resource.descriptor.mediaType,
            size: size, sha256: hash, capturedAt: item.capturedAt)
        let status: UploadResourceStatus = try await decode(
            "v1/uploads", method: "POST", body: encoder.encode(input))
        try status.validate(resource: resource)
        return status
    }

    func status(_ resource: UploadResource, item: UploadItem) async throws -> UploadResourceStatus {
        let status: UploadResourceStatus = try await decode("v1/uploads/\(resource.id.uuidString)")
        try status.validate(resource: resource)
        return status
    }

    func complete(_ resource: UploadResource) async throws -> UploadResourceStatus {
        let status: UploadResourceStatus = try await decode(
            "v1/uploads/\(resource.id.uuidString)/complete", method: "POST")
        try status.validate(resource: resource)
        return status
    }

    func retry(_ resource: UploadResource, item: UploadItem, library: UUID) async throws -> UploadResourceStatus {
        do {
            let status: UploadResourceStatus = try await decode(
                "v1/uploads/\(resource.id.uuidString)/retry", method: "POST")
            try status.validate(resource: resource)
            return status
        } catch let error as UploadFailure where error.status == 404 {
            return try await create(resource, item: item, library: library)
        }
    }

    func uploadRequest(_ resource: UploadResource, part: Int, policy: UploadPolicy) async throws -> URLRequest {
        guard let size = resource.expectedBytes, (0..<UploadChunk.count(size: size)).contains(part),
            policy != .disabled
        else { throw ClientError.invalid("The upload chunk or network policy is invalid.") }
        let saved = try await authorization.credentials()
        guard saved.connection.hasSameIdentity(as: connection) else { throw CancellationError() }
        var request = HTTP.request(
            try url("v1/uploads/\(resource.id.uuidString)/parts/\(part)"), method: "PUT", token: saved.accessToken)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(UploadChunk.size(part: part, total: size)), forHTTPHeaderField: "Content-Length")
        request.allowsCellularAccess = policy == .allNetworks
        request.allowsExpensiveNetworkAccess = policy == .allNetworks
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = 7 * 24 * 60 * 60
        return request
    }

    func manifest(_ item: UploadItem) async throws -> UploadResourceSetManifest? {
        let result: UploadResourceSetManifest
        do {
            result = try await decode(
                "v1/resource-sets/\(item.resourceSetID.uuidString)")
        } catch let error as UploadFailure where error.status == 404 {
            return nil
        }
        guard result.matches(item) else { throw ClientError.invalid("The stored backup belongs to another source.") }
        for resource in result.resources {
            let evidence: Backup = try await decode("v1/assets/\(resource.assetId.uuidString)/backup")
            guard evidence.id == resource.assetId, evidence.sha256 == resource.sha256,
                evidence.size == resource.size, evidence.available
            else { throw ClientError.invalid("The original backup resource is unavailable.") }
        }
        return result
    }

    func commit(_ item: UploadItem, library: UUID) async throws {
        let input = try UploadResourceSetManifest.input(item)
        let response: UploadResourceSetManifest = try await decode(
            "v1/libraries/\(library.uuidString)/resource-sets/\(item.resourceSetID.uuidString)",
            method: "PUT", body: JSONEncoder().encode(input))
        guard response.matches(item),
            response.resources.sorted(by: { $0.assetId.uuidString < $1.assetId.uuidString })
                == input.resources.sorted(by: { $0.assetId.uuidString < $1.assetId.uuidString })
        else { throw ClientError.invalid("The server did not commit the complete original resource set.") }
    }

    private func url(_ path: String) throws -> URL {
        guard let relative = URLComponents(string: path), relative.scheme == nil, relative.host == nil,
            relative.fragment == nil,
            let url = URL(string: path, relativeTo: connection.baseURL.appendingPathComponent("/"))?.absoluteURL,
            URLPolicy.sameOrigin(url, connection.baseURL)
        else { throw ClientError.invalid("The upload endpoint is outside the configured server.") }
        return url
    }

    private func decode<T: Decodable & Sendable>(
        _ path: String, method: String = "GET", body: Data? = nil
    ) async throws -> T {
        try JSONDecoder().decode(T.self, from: await send(path, method: method, body: body))
    }

    private func send(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        for attempt in 0..<2 {
            let credentials = try await authorization.credentials(forceRefresh: attempt > 0)
            guard credentials.connection.hasSameIdentity(as: connection) else { throw CancellationError() }
            let request = HTTP.request(try url(path), method: method, body: body, token: credentials.accessToken)
            let (data, response) = try await HTTP.response(request, maximum: 2 * 1024 * 1024, session: session)
            guard let http = response as? HTTPURLResponse else { throw ClientError.invalid("Invalid upload response.") }
            if http.statusCode == 401 && attempt == 0 { continue }
            guard (200..<300).contains(http.statusCode) else {
                let problem = try? JSONDecoder().decode(Problem.self, from: data)
                let message = problem?.detail ?? problem?.title ?? "The server could not complete this upload request."
                throw UploadFailure(
                    status: http.statusCode, message: String(message.prefix(2_000)),
                    retryable: [408, 425, 429, 500, 502, 503, 504].contains(http.statusCode)
                        || http.statusCode == 409 && message.hasPrefix("Blob cleanup is pending.")
                        || http.statusCode == 507 && message.hasPrefix("Pending upload budget exhausted."))
            }
            return data
        }
        throw UploadFailure(status: 401, message: "The server rejected the refreshed upload session.", retryable: false)
    }
}
