import Foundation

struct UploadTransfer: Codable, Equatable, Identifiable, Sendable {
    let scope: String
    let itemID: UUID
    let generation: UUID
    let resourceID: UUID
    let part: Int
    let bytes: Int64

    var id: UUID {
        UploadIdentity.id([
            "nephos-transfer-v1", scope, itemID.uuidString, generation.uuidString,
            resourceID.uuidString, String(part),
        ])
    }

    var isValid: Bool {
        !scope.isEmpty && scope.count <= 256 && part >= 0
            && part < UploadChunk.count(size: UploadChunk.maximumBytes)
            && bytes > 0 && bytes <= UploadChunk.byteCount
    }

    func taskDescription() throws -> String {
        guard isValid else { throw ClientError.invalid("Invalid background upload task.") }
        return String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    static func parse(_ description: String?) throws -> Self {
        guard let description, description.utf8.count <= 2048 else {
            throw ClientError.invalid("Missing background upload task identity.")
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(description.utf8))
        guard value.isValid else { throw ClientError.invalid("Invalid background upload task identity.") }
        return value
    }
}
