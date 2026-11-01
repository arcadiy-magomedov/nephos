import Foundation
import Photos
import UniformTypeIdentifiers

struct VerifiedExport: Sendable {
    let directory: URL
    let files: [URL]
    let manifest: ResourceManifest?
    let parts: [ResourcePart]
    let createdAt: String
    var shareFiles: [URL] { files + [directory.appendingPathComponent("manifest.json")] }

    static func download(asset: Asset, manifest: ResourceManifest?, api: API, root: URL) async throws -> VerifiedExport
    {
        if let manifest { try manifest.validate(primary: asset) }
        let parts =
            manifest?.resources ?? [
                ResourcePart(
                    assetId: asset.id, role: asset.isVideo ? "video" : "photo",
                    sha256: asset.sha256, size: asset.size, fileName: asset.fileName,
                    uniformTypeIdentifier: UTType(mimeType: asset.mediaType)?.identifier ?? UTType.data.identifier)
            ]
        let total = parts.reduce(Int64(0)) { $0 + $1.size }
        guard total > 0, total <= LedgerStore.stagingBudget else {
            throw ClientError.invalid(
                "The complete set exceeds the 10 GiB export budget. No partial set is offered as a complete backup.")
        }
        let free =
            try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard free > total + 64 * 1024 * 1024 else {
            throw ClientError.invalid("Not enough free storage for the complete original resource set.")
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var files: [URL] = []
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                let resource = Asset(
                    id: part.assetId, libraryId: asset.libraryId, fileName: part.fileName,
                    mediaType: UTType(part.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream",
                    size: part.size, sha256: part.sha256, createdAt: asset.createdAt, hasPreview: false)
                let file = try await MediaCache.original(
                    resource, api: api, directory: directory, maximum: LedgerStore.stagingBudget)
                let safeName = URL(fileURLWithPath: part.fileName).lastPathComponent
                let named = directory.appendingPathComponent("\(index)-\(safeName.isEmpty ? "original" : safeName)")
                try FileManager.default.moveItem(at: file, to: named)
                files.append(named)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = try manifest.map { try encoder.encode($0) } ?? encoder.encode(asset)
            try json.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
            try Task.checkCancellation()
            return VerifiedExport(
                directory: directory, files: files, manifest: manifest, parts: parts, createdAt: asset.createdAt)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    var canRestore: Bool {
        let allowed: Bool
        if let manifest {
            allowed = manifest.restoreSupported
        } else {
            allowed =
                parts.count == 1
                && (UTType(parts[0].uniformTypeIdentifier)?.conforms(to: .image) == true
                    || UTType(parts[0].uniformTypeIdentifier)?.conforms(to: .movie) == true)
        }
        return allowed
            && PHAssetCreationRequest.supportsAssetResourceTypes(
                parts.map { NSNumber(value: Self.resourceType($0.role).rawValue) })
    }
    private static func resourceType(_ role: String) -> PHAssetResourceType {
        switch role {
        case "video": return .video
        case "pairedVideo": return .pairedVideo
        case "alternatePhoto": return .alternatePhoto
        default: return .photo
        }
    }

    @MainActor
    @discardableResult
    func saveToPhotos() async throws -> String {
        guard canRestore else {
            throw ClientError.invalid(
                "This set contains edits or unsupported Photos resource roles. Export every original and its manifest to Files; cleanup remains blocked."
            )
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ClientError.invalid("Photos add permission was denied. Export to Files instead.")
        }
        try Task.checkCancellation()
        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            identifier = request.placeholderForCreatedAsset?.localIdentifier
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            request.creationDate = formatter.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
            for (index, part) in parts.enumerated() {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = part.fileName
                options.uniformTypeIdentifier = part.uniformTypeIdentifier
                options.shouldMoveFile = false
                request.addResource(with: Self.resourceType(part.role), fileURL: files[index], options: options)
            }
        }
        guard let identifier else {
            throw ClientError.invalid("Photos reported success without a created asset identifier.")
        }
        return identifier
    }
}
