import Foundation

protocol UploadRepository: Sendable {
    func snapshot(scope: String, limit: Int) async throws -> UploadSnapshot
    func setPolicy(_ policy: UploadPolicy, scope: String) async throws
    func setPaused(_ paused: Bool, scope: String) async throws
    func setNotice(_ notice: String?, scope: String) async throws
    func beginDiscovery(scope: String) async throws
    func appendDiscovery(_ candidates: [UploadCandidate], scope: String) async throws
    func finishDiscovery(
        _ candidates: [UploadCandidate], checkpoint: Data?, scope: String
    ) async throws
    func checkpoint(scope: String) async throws -> Data?
    func pending(scope: String, limit: Int) async throws -> [UploadItem]
    func item(id: UUID, scope: String) async throws -> UploadItem?
    func items(localIdentifiers: [String], scope: String) async throws -> [UploadItem]
    func update(_ item: UploadItem) async throws
    func retryFailed(scope: String) async throws
}
