import CryptoKit
import Foundation

enum UploadIdentity {
    static func id(_ parts: [String]) -> UUID {
        var data = Data()
        for part in parts {
            let bytes = Data(part.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    static func resourceSet(scope: String, candidate: UploadCandidate) -> UUID {
        id(["nephos-resource-set-v1", scope, candidate.localIdentifier, candidate.sourceRevision])
    }

    static func resources(scope: String, candidate: UploadCandidate) -> [UploadResource] {
        candidate.resources.enumerated().map { index, descriptor in
            UploadResource(
                id: id([
                    "nephos-resource-v1", scope, candidate.localIdentifier, candidate.sourceRevision,
                    String(index), String(descriptor.type), descriptor.filename,
                ]), descriptor: descriptor)
        }
    }
}
