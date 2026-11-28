import Foundation

enum UploadSourceRevision {
    struct Metadata {
        let capturedAt: Date?
        let modifiedAt: Date?
        let width: Int
        let height: Int
        let duration: TimeInterval
    }

    static func make(
        localIdentifier: String, metadata: Metadata, resources: [UploadResourceDescriptor]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let manifest = try encoder.encode(resources)
        return Hashing.sha256(
            Data(
                [
                    "nephos-photos-source-v1", localIdentifier,
                    metadata.capturedAt.map { String($0.timeIntervalSince1970) } ?? "unknown",
                    metadata.modifiedAt.map { String($0.timeIntervalSince1970) } ?? "unknown",
                    String(metadata.width), String(metadata.height), String(metadata.duration),
                    manifest.base64EncodedString(),
                ].joined(separator: "\n").utf8))
    }
}
