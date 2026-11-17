import Foundation

enum UploadResourcePhase: String, Codable, Sendable {
    case pending, scheduled, receiving, verifying, ready, failed
}
