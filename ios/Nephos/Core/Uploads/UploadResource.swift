import Foundation

struct UploadResource: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let descriptor: UploadResourceDescriptor
    var phase: UploadResourcePhase = .pending
    var expectedBytes: Int64?
    var receivedBytes: Int64 = 0
    var confirmedParts: Set<Int> = []
    var needsRestart = false
    var sha256: String?
    var attempts = 0
    var retryAfter: Date?
    var error: String?
}
