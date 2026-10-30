import Foundation

@MainActor
final class UploadClient {
    let api: API
    init(api: API) { self.api = api }

    func begin(_ record: UploadRecord) async throws -> UploadStatus {
        try await api.json(
            UploadStatus.self, "v1/uploads", method: "POST",
            body: JSONEncoder().encode(UploadIntent(record)))
    }
    func status(_ id: UUID) async throws -> UploadStatus {
        try await api.json(UploadStatus.self, "v1/uploads/\(id)")
    }
    func complete(_ id: UUID) async throws -> UploadStatus {
        try await api.json(UploadStatus.self, "v1/uploads/\(id)/complete", method: "POST", body: Data())
    }
    func evidence(_ id: UUID) async throws -> BackupEvidence {
        try await api.json(BackupEvidence.self, "v1/assets/\(id)/backup")
    }
    func retain(_ id: UUID) async throws -> RetentionHold {
        try await api.json(RetentionHold.self, "v1/assets/\(id)/retention", method: "POST", body: Data())
    }
    func originalRequest(_ id: UUID) async throws -> URLRequest {
        var request = try await api.request("v1/assets/\(id)/original")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return request
    }
    func sendPart(
        _ record: UploadRecord, index: Int, file: URL,
        using transport: @MainActor (URLRequest, URL) async throws -> Void
    ) async throws {
        let length = try Chunking.length(index: index, size: record.size, chunkSize: api.connection.config.chunkSize)
        let actual = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard actual == length else {
            throw ClientError.invalid("Upload part file length does not match its immutable intent.")
        }
        var request = try await api.request("v1/uploads/\(record.id)/parts/\(index)", method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(length), forHTTPHeaderField: "Content-Length")
        try await transport(request, file)
    }
    static func foregroundPart(_ request: URLRequest, _ file: URL) async throws {
        let (_, response) = try await HTTP.session.upload(for: request, fromFile: file)
        try HTTP.check(response)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else {
            throw ClientError.invalid("Upload part was not acknowledged with HTTP 204.")
        }
    }
}
