import Photos
import PhotosUI
import SwiftUI

struct LivePhotoPlaybackView: UIViewRepresentable {
    let item: LocalMediaItem
    let playRequest: Int
    let failed: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.item != item {
            coordinator.cancel()
            coordinator.item = item
            view.livePhoto = nil
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject else {
                failed("This Live Photo is no longer available.")
                return
            }
            let options = PHLivePhotoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            coordinator.request = coordinator.manager.requestLivePhoto(
                for: asset, targetSize: CGSize(width: 2048, height: 2048), contentMode: .aspectFit, options: options
            ) { [weak view, weak coordinator] photo, info in
                let error = info?[PHImageErrorKey] as? Error
                Task { @MainActor in
                    guard coordinator?.item == item else { return }
                    if let photo { view?.livePhoto = photo } else if let error { failed(error.localizedDescription) }
                }
            }
        }
        if coordinator.playRequest != playRequest {
            coordinator.playRequest = playRequest
            view.startPlayback(with: .full)
        }
    }

    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        coordinator.cancel()
        view.stopPlayback()
    }

    @MainActor
    final class Coordinator {
        let manager = PHImageManager.default()
        var item: LocalMediaItem?
        var request: PHImageRequestID?
        var playRequest = 0

        func cancel() {
            if let request { manager.cancelImageRequest(request) }
            request = nil
            item = nil
        }
    }
}
