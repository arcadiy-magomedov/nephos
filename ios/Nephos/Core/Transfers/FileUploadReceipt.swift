import Foundation

struct FileUploadReceipt: Codable, Sendable {
    let upload: FileUploadDescriptor
    let status: Int?
    let error: String?
    let cancelled: Bool
    let completedAt: Date
}
