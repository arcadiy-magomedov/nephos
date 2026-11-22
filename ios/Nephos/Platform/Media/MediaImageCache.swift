import Photos

@MainActor
enum MediaImageCache {
    static let manager = PHCachingImageManager()
}
