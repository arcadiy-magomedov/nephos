import Foundation

protocol UploadPhotoSource: Sendable {
    func discover(repository: any UploadRepository, scope: String) async throws
    func export(item: UploadItem, resource: UploadResource, to file: URL) async throws
}
