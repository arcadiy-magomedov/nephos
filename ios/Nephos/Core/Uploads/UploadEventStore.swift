import Foundation

struct UploadEventStore: Sendable {
    let files: FileUploadEventStore

    init(directory: URL) {
        files = FileUploadEventStore(
            directory: directory.appendingPathComponent("file-upload-events", isDirectory: true))
    }

    func record(_ receipt: UploadTransferReceipt) throws {
        try files.record(
            FileUploadReceipt(
                upload: receipt.transfer.fileDescriptor(), status: receipt.status, error: receipt.error,
                cancelled: receipt.cancelled, completedAt: receipt.completedAt))
    }

    func receipts(scope: String) async throws -> [UploadTransferReceipt] {
        try await files.receipts(scope: scope).map {
            UploadTransferReceipt(
                transfer: try UploadTransfer(descriptor: $0.upload), status: $0.status, error: $0.error,
                cancelled: $0.cancelled, completedAt: $0.completedAt)
        }
    }

    func acknowledge(_ receipt: UploadTransferReceipt) async throws {
        try await files.acknowledge(id: receipt.transfer.id)
    }

    func update(_ transfer: UploadTransfer, bytes: Int64) async {
        await files.update(
            FileUploadDescriptor(id: transfer.id, scope: transfer.scope, byteCount: transfer.bytes, context: Data()),
            bytes: bytes)
    }

    func sent(_ transfer: UploadTransfer) async -> Int64 { await files.sent(id: transfer.id) }
}
