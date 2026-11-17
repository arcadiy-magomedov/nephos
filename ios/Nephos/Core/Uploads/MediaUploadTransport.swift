import Foundation
import OSLog

struct MediaUploadTransport: UploadTransport {
    let files: any FileUploadTransport
    private let logger = Logger(subsystem: "app.nephos.ios", category: "MediaUploadAdapter")

    func active() async -> [UploadTransfer] {
        var result: [UploadTransfer] = []
        for descriptor in await files.active() {
            do { result.append(try UploadTransfer(descriptor: descriptor)) } catch {
                await files.cancel(ids: [descriptor.id])
                logger.error(
                    "Cancelled an invalid media transfer mapping: \(error.localizedDescription, privacy: .private)")
            }
        }
        return result
    }

    func enqueue(_ transfer: UploadTransfer, request: URLRequest, file: URL) async throws {
        try await files.enqueue(transfer.fileDescriptor(), request: request, file: file)
    }

    func cancel(scope: String?) async { await files.cancel(scope: scope) }
}
