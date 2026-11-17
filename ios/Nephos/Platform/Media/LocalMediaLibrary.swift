import Observation
import Photos

@MainActor
@Observable
final class LocalMediaLibrary: NSObject, PHPhotoLibraryChangeObserver {
    enum Filter: String, CaseIterable {
        case all = "All"
        case photos = "Photos"
        case videos = "Videos"
    }

    private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var items: [LocalMediaItem] = []
    private(set) var days: [LocalMediaDay] = []
    private(set) var hasMore = false
    private(set) var filter: Filter = .all
    @ObservationIgnored let images = MediaImageCache.manager
    @ObservationIgnored private var assets: PHFetchResult<PHAsset>?
    @ObservationIgnored private let pageSize = 180
    @ObservationIgnored private var observing = false

    deinit {
        if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    var hasAccess: Bool { authorization == .authorized || authorization == .limited }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refresh()
    }

    func refreshAuthorization() {
        if authorization != PHPhotoLibrary.authorizationStatus(for: .readWrite) { refresh() }
    }

    func refresh() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard hasAccess else {
            if observing {
                PHPhotoLibrary.shared().unregisterChangeObserver(self)
                observing = false
                images.stopCachingImagesForAllAssets()
            }
            assets = nil
            items = []
            days = []
            hasMore = false
            return
        }
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        let count = max(pageSize, items.count)
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        switch filter {
        case .all:
            options.predicate = NSPredicate(
                format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue)
        case .photos:
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .videos:
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        }
        assets = PHAsset.fetchAssets(with: options)
        replaceItems(upTo: count)
    }

    func select(_ filter: Filter) {
        guard self.filter != filter else { return }
        self.filter = filter
        items = []
        refresh()
    }

    func loadMore() {
        guard hasMore, let assets else { return }
        let end = min(items.count + pageSize, assets.count)
        items.append(contentsOf: (items.count..<end).map { Self.item(assets.object(at: $0)) })
        days = LocalMediaDay.group(items)
        hasMore = end < assets.count
    }

    func neighbor(of item: LocalMediaItem, offset: Int) -> LocalMediaItem? {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        let target = index + offset
        if target >= items.count { loadMore() }
        return items.indices.contains(target) ? items[target] : nil
    }

    func contains(_ item: LocalMediaItem) -> Bool {
        guard hasAccess else { return false }
        return PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).count == 1
    }

    func canDelete(_ item: LocalMediaItem) -> Bool {
        PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject?.canPerform(.delete) == true
    }

    func delete(_ item: LocalMediaItem) async throws -> Bool {
        let asset = try Self.asset(item.id)
        guard asset.canPerform(.delete) else { throw LocalMediaError.deletionUnsupported }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }
        } catch {
            let failure = error as NSError
            if failure.domain == PHPhotosErrorDomain || failure.domain == NSCocoaErrorDomain,
                failure.code == PHPhotosError.Code.userCancelled.rawValue
            {
                return false
            }
            throw error
        }
        refresh()
        return true
    }

    static func asset(_ id: String) throws -> PHAsset {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw LocalMediaError.unavailable
        }
        return asset
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.refresh() }
    }

    private func replaceItems(upTo count: Int) {
        guard let assets else { return }
        let end = min(count, assets.count)
        var next: [LocalMediaItem] = []
        next.reserveCapacity(end)
        for index in 0..<end {
            next.append(Self.item(assets.object(at: index)))
        }
        items = next
        days = LocalMediaDay.group(next)
        hasMore = end < assets.count
    }

    private static func item(_ asset: PHAsset) -> LocalMediaItem {
        LocalMediaItem(
            id: asset.localIdentifier, kind: asset.mediaType == .video ? .video : .photo,
            capturedAt: asset.creationDate, modifiedAt: asset.modificationDate, duration: asset.duration,
            pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive))
    }
}
