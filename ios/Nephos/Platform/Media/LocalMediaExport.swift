import Foundation
import OSLog
import Photos

struct LocalMediaExport: Identifiable {
    let id = UUID()
    let directory: URL
    let files: [URL]

    @MainActor
    static func prepare(_ item: LocalMediaItem) async throws -> LocalMediaExport {
        let asset = try LocalMediaLibrary.asset(item.id)
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: PHAssetResourceType = item.kind == .video ? .fullSizeVideo : .fullSizePhoto
        let fallback: PHAssetResourceType = item.kind == .video ? .video : .photo
        guard
            let resource = resources.first(where: { $0.type == preferred })
                ?? resources.first(where: { $0.type == fallback })
        else { throw LocalMediaError.exportUnavailable }
        let selected: [PHAssetResource]
        if item.isLivePhoto {
            guard let photo = resources.first(where: { $0.type == .photo }),
                let video = resources.first(where: { $0.type == .pairedVideo })
            else { throw LocalMediaError.exportUnavailable }
            selected = [photo, video]
        } else {
            selected = [resource]
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nephos-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        do {
            try Task.checkCancellation()
            var files: [URL] = []
            for resource in selected {
                let file = directory.appendingPathComponent((resource.originalFilename as NSString).lastPathComponent)
                try await PhotoResourceExport().write(resource, to: file)
                try Task.checkCancellation()
                files.append(file)
            }
            return LocalMediaExport(directory: directory, files: files)
        } catch {
            remove(directory)
            throw error
        }
    }

    static func remove(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Logger(subsystem: "app.nephos.ios", category: "MediaExport")
                .error("Unable to remove temporary share files: \(error.localizedDescription, privacy: .private)")
        }
    }
}
