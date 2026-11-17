import Foundation

struct UploadTransferReceipt: Codable, Sendable {
    let transfer: UploadTransfer
    let status: Int?
    let error: String?
    let cancelled: Bool
    let completedAt: Date
}
