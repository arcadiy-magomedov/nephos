import Foundation

protocol UploadTransport: Sendable {
    func active() async -> [UploadTransfer]
    func enqueue(_ transfer: UploadTransfer, request: URLRequest, file: URL) async throws
    func cancel(scope: String?) async
}
