import Foundation

struct UploadResourceDescriptor: Codable, Equatable, Sendable {
    let type: Int
    let role: String
    let filename: String
    let uniformTypeIdentifier: String
    let mediaType: String
    let isPrimary: Bool
}
