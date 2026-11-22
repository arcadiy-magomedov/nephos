import Observation
import Photos
import UIKit

@MainActor
@Observable
final class PhotoImageLoader {
    private(set) var image: UIImage?
    private(set) var error: String?
    private(set) var progress: Double = 0
    @ObservationIgnored private var request = PHInvalidImageRequestID
    @ObservationIgnored private var manager: PHImageManager?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var assetID: String?

    func load(
        _ id: String, size: CGSize, thumbnail: Bool, manager: PHImageManager
    ) {
        cancel()
        if assetID != id { image = nil }
        assetID = id
        error = nil
        progress = 0
        self.manager = manager
        let version = generation
        do {
            let asset = try LocalMediaLibrary.asset(id)
            let options = PHImageRequestOptions()
            options.deliveryMode = thumbnail ? .opportunistic : .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = !thumbnail
            options.progressHandler = { [weak self] value, _, _, _ in
                Task { @MainActor in
                    guard let self, self.generation == version else { return }
                    self.progress = value
                }
            }
            request = manager.requestImage(
                for: asset, targetSize: size, contentMode: thumbnail ? .aspectFill : .aspectFit,
                options: options
            ) { [weak self] image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                let failure = (info?[PHImageErrorKey] as? Error)?.localizedDescription
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
                Task { @MainActor in
                    guard let self, self.generation == version, !cancelled else { return }
                    if let image { self.image = image }
                    if let failure {
                        self.error = failure
                    } else if image == nil, !degraded {
                        self.error =
                            inCloud && thumbnail
                            ? "Open this item to load its preview from iCloud."
                            : "Photos could not load this image. Check your connection and try again."
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cancel() {
        generation = UUID()
        if request != PHInvalidImageRequestID { manager?.cancelImageRequest(request) }
        request = PHInvalidImageRequestID
    }
}
