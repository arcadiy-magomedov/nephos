import Foundation

enum UploadPhase: String, Codable, Sendable {
    case queued, preparing, scheduled, uploading, verifying, succeeded, failed

    var isTerminal: Bool { self == .succeeded || self == .failed }
}
