import Foundation

struct UploadLibrary: Decodable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let isShared: Bool
}
