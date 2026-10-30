import Foundation
import Photos
import UniformTypeIdentifiers

final class ExportSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let maximum: Int64
    private var count: Int64 = 0
    private var failure: Error?
    private var requestID: PHAssetResourceDataRequestID?
    init(url: URL, maximum: Int64) throws {
        self.maximum = maximum
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ClientError.invalid("Cannot create an original staging file.")
        }
        handle = try FileHandle(forWritingTo: url)
    }
    func append(_ data: Data) {
        lock.lock()
        guard failure == nil else {
            lock.unlock()
            return
        }
        do {
            guard count + Int64(data.count) <= maximum else {
                throw ClientError.invalid("Original exceeds the staging/free-space limit. Nothing was deleted.")
            }
            try handle.write(contentsOf: data)
            count += Int64(data.count)
        } catch { failure = error }
        let cancelID = failure == nil ? nil : requestID
        lock.unlock()
        if let cancelID { PHAssetResourceManager.default().cancelDataRequest(cancelID) }
    }
    func bind(_ id: PHAssetResourceDataRequestID) {
        lock.lock()
        requestID = id
        let shouldCancel = failure != nil
        lock.unlock()
        if shouldCancel { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
    func cancel() {
        lock.lock()
        failure = failure ?? CancellationError()
        let id = requestID
        lock.unlock()
        if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
    func finish(_ error: Error?) throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.synchronize()
        try handle.close()
        if let error = failure ?? error { throw error }
        guard count > 0 else { throw ClientError.invalid("Photos exported an empty resource.") }
    }
}

@MainActor
final class PhotosLibrary: NSObject, PHPhotoLibraryChangeObserver {
    var onChange: (() -> Void)?
    private var observing = false
    override init() {
        super.init()
        refreshObservation()
    }
    deinit { if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self) } }
    func refreshObservation() {
        let allowed = authorization == .authorized || authorization == .limited
        if allowed && !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        if !allowed && observing {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
            observing = false
        }
    }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.onChange?() }
    }
    var authorization: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
    func requestAccess() async -> PHAuthorizationStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refreshObservation()
        return status
    }
    func asset(_ identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }
    func revision(_ asset: PHAsset) -> SourceRevision {
        let resources = PHAssetResource.assetResources(for: asset)
        let resource = resources.first
        let supportedTypes: Set<String> = [
            "public.jpeg", "public.png", "public.heic", "public.heif",
            "public.tiff", "com.compuserve.gif", "com.apple.quicktime-movie", "public.mpeg-4",
        ]
        let single =
            resources.count == 1
            && resource.map {
                ($0.type == .photo && asset.mediaType == .image || $0.type == .video && asset.mediaType == .video)
                    && supportedTypes.contains($0.uniformTypeIdentifier)
            } == true && !asset.mediaSubtypes.contains(.photoLive)
        return SourceRevision(
            localIdentifier: asset.localIdentifier,
            modificationTime: asset.modificationDate?.timeIntervalSince1970 ?? -1,
            resourceNames: resources.map(\.originalFilename), resourceTypes: resources.map { $0.type.rawValue },
            pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, duration: asset.duration,
            cleanupSupported: single && asset.modificationDate != nil,
            creationTime: asset.creationDate?.timeIntervalSince1970,
            resourceUTIs: resources.map(\.uniformTypeIdentifier))
    }
    func resources(_ asset: PHAsset) -> [PHAssetResource] { PHAssetResource.assetResources(for: asset) }
    func mime(_ resource: PHAssetResource) -> String {
        let mime = UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream"
        let supported = [
            "image/jpeg", "image/png", "image/heic", "image/heif", "image/gif", "video/quicktime", "video/mp4",
        ]
        return supported.contains(mime) ? mime : "application/octet-stream"
    }
    func role(_ resource: PHAssetResource) -> String {
        switch resource.type {
        case .photo: return "photo"
        case .video: return "video"
        case .audio: return "audio"
        case .alternatePhoto: return "alternatePhoto"
        case .fullSizePhoto: return "fullSizePhoto"
        case .fullSizeVideo: return "fullSizeVideo"
        case .adjustmentData: return "adjustmentData"
        case .adjustmentBasePhoto: return "adjustmentBasePhoto"
        case .pairedVideo: return "pairedVideo"
        case .fullSizePairedVideo: return "fullSizePairedVideo"
        case .adjustmentBasePairedVideo: return "adjustmentBasePairedVideo"
        case .adjustmentBaseVideo: return "adjustmentBaseVideo"
        case .photoProxy: return "photoProxy"
        @unknown default: return "unknown-\(resource.type.rawValue)"
        }
    }
    func kind(_ asset: PHAsset) -> String {
        let roles = resources(asset).map(role)
        if roles.contains(where: { $0.hasPrefix("adjustment") || $0.hasPrefix("fullSize") }) { return "edited" }
        if asset.mediaSubtypes.contains(.photoLive), roles.sorted() == ["pairedVideo", "photo"] { return "live-photo" }
        if roles.sorted() == ["alternatePhoto", "photo"] { return "raw-jpeg" }
        return roles.count == 1 ? "single" : "archive"
    }
    func batch(after identifier: String?, count: Int = 12) -> (assets: [PHAsset], atEnd: Bool) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue)
        let fetch = PHAsset.fetchAssets(with: options)
        var start = 0
        if let identifier, let previous = asset(identifier) {
            let index = fetch.index(of: previous)
            if index != NSNotFound { start = index + 1 }
        }
        let end = min(start + count, fetch.count)
        guard start < end else { return ([], true) }
        return ((start..<end).map { fetch.object(at: $0) }, end == fetch.count)
    }
    func export(_ resource: PHAssetResource, to url: URL, maximum: Int64, allowNetwork: Bool) async throws {
        let sink = try ExportSink(url: url, maximum: maximum)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let id = PHAssetResourceManager.default().requestData(
                        for: resource, options: options,
                        dataReceivedHandler: { sink.append($0) },
                        completionHandler: { error in
                            do {
                                try sink.finish(error)
                                continuation.resume()
                            } catch { continuation.resume(throwing: error) }
                        })
                    sink.bind(id)
                }
            } onCancel: {
                sink.cancel()
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
