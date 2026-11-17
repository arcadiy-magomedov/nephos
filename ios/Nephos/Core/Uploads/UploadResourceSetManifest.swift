import Foundation

struct UploadResourceSetManifest: Codable, Sendable {
    struct Resource: Codable, Equatable, Sendable {
        let assetId: UUID
        let role: String
        let sha256: String
        let size: Int64
        let fileName: String
        let uniformTypeIdentifier: String
    }

    let id: UUID?
    let kind: String
    let sourceRevision: String
    let primaryAssetId: UUID
    let resources: [Resource]

    static func input(_ item: UploadItem) throws -> UploadResourceSetManifest {
        guard let primary = item.primaryResource,
            item.resources.allSatisfy({
                $0.phase == .ready && $0.sha256?.count == 64 && ($0.expectedBytes ?? 0) > 0
            })
        else { throw ClientError.invalid("The complete media resource set is not ready.") }
        return UploadResourceSetManifest(
            id: item.resourceSetID, kind: item.kind, sourceRevision: item.sourceRevision,
            primaryAssetId: primary.id,
            resources: item.resources.map {
                Resource(
                    assetId: $0.id, role: $0.descriptor.role, sha256: $0.sha256!,
                    size: $0.expectedBytes!, fileName: $0.descriptor.filename,
                    uniformTypeIdentifier: $0.descriptor.uniformTypeIdentifier)
            })
    }

    func matches(_ item: UploadItem) -> Bool {
        guard id == item.resourceSetID, kind == item.kind, sourceRevision == item.sourceRevision,
            primaryAssetId == item.primaryResource?.id, resources.count == item.resources.count
        else { return false }
        return item.resources.allSatisfy { local in
            resources.contains {
                $0.assetId == local.id && $0.role == local.descriptor.role
                    && $0.fileName == local.descriptor.filename
                    && $0.uniformTypeIdentifier == local.descriptor.uniformTypeIdentifier
                    && $0.size > 0 && $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit)
            }
        }
    }
}
