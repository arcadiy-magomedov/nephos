import Foundation

struct UploadItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let batchID: UUID
    let scope: String
    var generation = UUID()
    var resourceSetID: UUID
    var localIdentifier: String
    var sourceRevision: String
    var kind: String
    var capturedAt: Date?
    var resources: [UploadResource]
    var phase: UploadPhase
    var committed = false
    var error: String?
    let createdAt: Date
    var updatedAt: Date

    var primaryResource: UploadResource? { resources.first { $0.descriptor.isPrimary } }
    var filename: String { primaryResource?.descriptor.filename ?? "Media" }
    var receivedBytes: Int64 { resources.reduce(0) { $0 + max(0, $1.receivedBytes) } }
    var totalBytes: Int64? {
        guard !resources.isEmpty, resources.allSatisfy({ ($0.expectedBytes ?? 0) > 0 }) else { return nil }
        return resources.reduce(0) { $0 + ($1.expectedBytes ?? 0) }
    }
    var progress: Double? {
        if phase == .succeeded { return 1 }
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }
}
