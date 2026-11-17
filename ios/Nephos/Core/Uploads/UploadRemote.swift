import Foundation

protocol UploadRemote: Sendable {
    func create(_ resource: UploadResource, item: UploadItem, library: UUID) async throws -> UploadResourceStatus
    func retry(_ resource: UploadResource, item: UploadItem, library: UUID) async throws -> UploadResourceStatus
    func complete(_ resource: UploadResource) async throws -> UploadResourceStatus
    func uploadRequest(_ resource: UploadResource, part: Int, policy: UploadPolicy) async throws -> URLRequest
    func manifest(_ item: UploadItem) async throws -> UploadResourceSetManifest?
    func commit(_ item: UploadItem, library: UUID) async throws
    func refreshAuthorization() async throws
}
