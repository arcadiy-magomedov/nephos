import Foundation

struct UploadSnapshot: Sendable {
    let policy: UploadPolicy
    let paused: Bool
    let scanning: Bool
    let notice: String?
    let batch: UploadBatch?
    let succeeded: [UploadItem]
    let failed: [UploadItem]
    let pending: [UploadItem]
    let succeededCount: Int
    let failedCount: Int
    let pendingCount: Int

    static let empty = UploadSnapshot(
        policy: .disabled, paused: false, scanning: false, notice: nil, batch: nil,
        succeeded: [], failed: [], pending: [], succeededCount: 0, failedCount: 0, pendingCount: 0)

    var canTransfer: Bool { policy != .disabled && !paused }
}
