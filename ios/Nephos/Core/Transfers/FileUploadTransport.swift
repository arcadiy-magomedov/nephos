import Foundation

protocol FileUploadTransport: Sendable {
    func active() async -> [FileUploadDescriptor]
    func enqueue(_ upload: FileUploadDescriptor, request: URLRequest, file: URL) async throws
    func cancel(scope: String?) async
    func cancel(ids: Set<UUID>) async
}
