import Foundation
import Photos
import UniformTypeIdentifiers

actor UploadPhotoLibrary: UploadPhotoSource {
    func discover(repository: any UploadRepository, scope: String) async throws {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            throw ClientError.invalid(
                "Photos access is unavailable. Allow Photos access in Settings to resume uploads.")
        }
        try await repository.beginDiscovery(scope: scope)
        let library = PHPhotoLibrary.shared()
        let start = library.currentChangeToken
        var incremental = false
        if authorization == .authorized, let data = try await repository.checkpoint(scope: scope),
            let saved = try NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
        {
            do {
                for change in try library.fetchPersistentChanges(since: saved) {
                    try Task.checkCancellation()
                    let details = try change.changeDetails(for: .asset)
                    let identifiers = Array(details.insertedLocalIdentifiers.union(details.updatedLocalIdentifiers))
                    try await append(
                        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil),
                        repository: repository, scope: scope)
                    for var item in try await repository.items(
                        localIdentifiers: Array(details.deletedLocalIdentifiers), scope: scope
                    ) where item.phase != .succeeded {
                        item.phase = .failed
                        item.error =
                            """
                            This item was removed from Photos or is no longer accessible. \
                            Restore access before retrying.
                            """
                        try await repository.update(item)
                    }
                }
                incremental = true
            } catch let error as PHPhotosError where error.code == .persistentChangeTokenExpired {
                incremental = false
            }
        }
        if !incremental {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue)
            try await append(PHAsset.fetchAssets(with: options), repository: repository, scope: scope)
        }
        let checkpoint =
            authorization == .authorized
            ? try NSKeyedArchiver.archivedData(withRootObject: start, requiringSecureCoding: true) : nil
        try await repository.finishDiscovery([], checkpoint: checkpoint, scope: scope)
    }

    private func append(
        _ assets: PHFetchResult<PHAsset>, repository: any UploadRepository, scope: String
    ) async throws {
        var page: [UploadCandidate] = []
        for index in 0..<assets.count {
            try Task.checkCancellation()
            let asset = assets.object(at: index)
            if asset.mediaType == .image || asset.mediaType == .video {
                do {
                    let candidate = try Self.candidate(asset)
                    guard candidate.isValid else {
                        throw ClientError.invalid("Photos returned an unsupported or incomplete resource manifest.")
                    }
                    page.append(candidate)
                } catch {
                    page.append(
                        UploadCandidate(
                            localIdentifier: asset.localIdentifier,
                            sourceRevision: "unavailable-\(asset.modificationDate?.timeIntervalSince1970 ?? 0)",
                            kind: "archive", capturedAt: asset.creationDate, resources: [],
                            discoveryError: error.localizedDescription))
                }
            }
            if page.count >= 200 {
                try await repository.appendDiscovery(page, scope: scope)
                page.removeAll(keepingCapacity: true)
            }
        }
        if !page.isEmpty { try await repository.appendDiscovery(page, scope: scope) }
    }

    func export(item: UploadItem, resource: UploadResource, to file: URL) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.localIdentifier], options: nil).firstObject,
            try Self.candidate(asset).sourceRevision == item.sourceRevision,
            let original = PHAssetResource.assetResources(for: asset).first(where: {
                $0.type.rawValue == resource.descriptor.type
                    && $0.originalFilename == resource.descriptor.filename
                    && $0.uniformTypeIdentifier == resource.descriptor.uniformTypeIdentifier
            })
        else {
            throw ClientError.invalid("The photo changed or is no longer accessible. Refresh Photos before retrying.")
        }
        try await PhotoResourceExport().write(original, to: file)
    }

    static func candidate(_ asset: PHAsset) throws -> UploadCandidate {
        let originals = PHAssetResource.assetResources(for: asset).sorted {
            if $0.type != $1.type { return $0.type.rawValue < $1.type.rawValue }
            if $0.originalFilename != $1.originalFilename { return $0.originalFilename < $1.originalFilename }
            return $0.uniformTypeIdentifier < $1.uniformTypeIdentifier
        }
        let identities = originals.map {
            "\($0.type.rawValue)\n\($0.originalFilename)\n\($0.uniformTypeIdentifier)"
        }
        guard Set(identities).count == originals.count else {
            throw ClientError.invalid(
                "Photos returned indistinguishable resources. This item cannot be backed up safely.")
        }
        let primaryType: PHAssetResourceType = asset.mediaType == .video ? .fullSizeVideo : .fullSizePhoto
        let fallback: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        guard
            let primary = originals.first(where: { $0.type == primaryType })
                ?? originals.first(where: { $0.type == fallback })
        else {
            throw ClientError.invalid("Photos did not provide the primary original resource.")
        }
        let resources = originals.map { resource in
            let type = UTType(resource.uniformTypeIdentifier)
            let mediaType = type?.preferredMIMEType ?? "application/octet-stream"
            let supported = [
                "image/jpeg", "image/png", "image/heic", "image/heif", "image/webp", "image/gif",
                "video/mp4", "video/quicktime",
            ]
            return UploadResourceDescriptor(
                type: resource.type.rawValue, role: role(resource.type), filename: resource.originalFilename,
                uniformTypeIdentifier: resource.uniformTypeIdentifier,
                mediaType: supported.contains(mediaType) ? mediaType : "application/octet-stream",
                isPrimary: resource === primary)
        }
        let kind = kind(resources)
        let revision = try UploadSourceRevision.make(
            localIdentifier: asset.localIdentifier,
            metadata: UploadSourceRevision.Metadata(
                capturedAt: asset.creationDate, modifiedAt: asset.modificationDate,
                width: asset.pixelWidth, height: asset.pixelHeight, duration: asset.duration),
            resources: resources)
        return UploadCandidate(
            localIdentifier: asset.localIdentifier, sourceRevision: revision, kind: kind,
            capturedAt: asset.creationDate, resources: resources)
    }

    private static func kind(_ resources: [UploadResourceDescriptor]) -> String {
        let roles = Set(resources.map(\.role))
        let kind: String
        if resources.count == 1 {
            kind = "single"
        } else if resources.count == 2, roles == ["photo", "pairedVideo"] {
            kind = "live-photo"
        } else if resources.count == 2, roles == ["photo", "alternatePhoto"] {
            kind = "raw-jpeg"
        } else {
            kind = roles.contains(where: { $0.hasPrefix("unknown-") }) ? "archive" : "edited"
        }
        return kind
    }

    // Exhaustive PhotoKit-to-wire mapping has no branching logic beyond the enum cases.
    // swiftlint:disable:next cyclomatic_complexity
    private static func role(_ type: PHAssetResourceType) -> String {
        switch type {
        case .photo: "photo"
        case .video: "video"
        case .audio: "audio"
        case .alternatePhoto: "alternatePhoto"
        case .fullSizePhoto: "fullSizePhoto"
        case .fullSizeVideo: "fullSizeVideo"
        case .adjustmentData: "adjustmentData"
        case .adjustmentBasePhoto: "adjustmentBasePhoto"
        case .pairedVideo: "pairedVideo"
        case .fullSizePairedVideo: "fullSizePairedVideo"
        case .adjustmentBasePairedVideo: "adjustmentBasePairedVideo"
        case .adjustmentBaseVideo: "adjustmentBaseVideo"
        case .photoProxy: "photoProxy"
        @unknown default: "unknown-\(type.rawValue)"
        }
    }
}
