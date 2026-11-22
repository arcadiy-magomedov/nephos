import Foundation

struct UploadBatch: Identifiable, Equatable, Sendable {
    let id: UUID
    let total: Int
    let succeeded: Int
    let failed: Int
    let createdAt: Date
    let completedAt: Date?

    var progress: Double { total > 0 ? Double(succeeded) / Double(total) : 0 }
    var unfinished: Int { total - succeeded }
}
