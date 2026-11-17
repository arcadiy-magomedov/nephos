import Foundation

struct UploadFailure: LocalizedError, Sendable {
    let status: Int?
    let message: String
    let retryable: Bool

    var errorDescription: String? { message }
}
