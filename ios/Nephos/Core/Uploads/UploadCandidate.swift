import Foundation

struct UploadCandidate: Sendable {
    let localIdentifier: String
    let sourceRevision: String
    let kind: String
    let capturedAt: Date?
    let resources: [UploadResourceDescriptor]
    var discoveryError: String?

    var isValid: Bool {
        if discoveryError != nil {
            return !localIdentifier.isEmpty && !sourceRevision.isEmpty && sourceRevision.count <= 1024
        }
        let valid =
            !localIdentifier.isEmpty && !sourceRevision.isEmpty && sourceRevision.count <= 1024
            && ["single", "live-photo", "raw-jpeg", "edited", "archive"].contains(kind)
            && (1...16).contains(resources.count)
            && resources.filter(\.isPrimary).count == 1
            && resources.allSatisfy {
                !$0.filename.isEmpty && $0.filename.count <= 200 && !$0.role.isEmpty
                    && !$0.uniformTypeIdentifier.isEmpty && !$0.mediaType.isEmpty
            }
        guard valid else { return false }
        if kind == "live-photo" {
            return resources.count == 2 && Set(resources.map(\.role)) == ["photo", "pairedVideo"]
        }
        if kind == "raw-jpeg" {
            return resources.count == 2 && Set(resources.map(\.role)) == ["photo", "alternatePhoto"]
        }
        return kind != "single" || resources.count == 1
    }
}
