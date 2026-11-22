import Foundation

struct UploadResourceStatus: Decodable, Sendable {
    let id: UUID
    let state: String
    let chunkSize: Int
    let receivedParts: [Int]
    let assetId: UUID?
    let error: String?

    func validate(resource: UploadResource) throws {
        guard let size = resource.expectedBytes, size > 0, size <= UploadChunk.maximumBytes,
            id == resource.id, chunkSize == UploadChunk.byteCount,
            ["uploading", "verifying", "ready", "failed", "cancelled"].contains(state),
            receivedParts.count == Set(receivedParts).count,
            receivedParts.allSatisfy({ (0..<UploadChunk.count(size: size)).contains($0) }),
            state != "ready" || assetId == resource.id
        else { throw ClientError.invalid("The server returned inconsistent resource progress.") }
    }

    func receivedBytes(size: Int64) -> Int64 {
        if state == "ready" || state == "verifying" { return size }
        return receivedParts.reduce(0) { $0 + UploadChunk.size(part: $1, total: size) }
    }
}
