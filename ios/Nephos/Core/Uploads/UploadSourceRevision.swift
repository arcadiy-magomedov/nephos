import Foundation

enum UploadSourceRevision {
    static func make(
        localIdentifier: String, capturedAt: Date?, modifiedAt: Date?, width: Int, height: Int,
        duration: TimeInterval, resources: [UploadResourceDescriptor]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let manifest = try encoder.encode(resources)
        return Hashing.sha256(
            Data(
                [
                    "nephos-photos-source-v1", localIdentifier,
                    capturedAt.map { String($0.timeIntervalSince1970) } ?? "unknown",
                    modifiedAt.map { String($0.timeIntervalSince1970) } ?? "unknown",
                    String(width), String(height), String(duration), manifest.base64EncodedString(),
                ].joined(separator: "\n").utf8))
    }
}
