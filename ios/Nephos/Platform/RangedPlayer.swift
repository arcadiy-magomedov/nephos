import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class RangedPlayer: NSObject, @preconcurrency AVAssetResourceLoaderDelegate {
    let asset: Asset
    let api: API
    let urlAsset: AVURLAsset
    var onError: ((Error) -> Void)?
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var stopped = false

    init(asset: Asset, api: API) {
        self.asset = asset
        self.api = api
        urlAsset = AVURLAsset(url: URL(string: "nephos-media://original/\(asset.id)")!)
        super.init()
        urlAsset.resourceLoader.setDelegate(self, queue: .main)
    }
    func stop() {
        stopped = true
        for request in requests.values {
            request.cancel()
        }
        requests.removeAll()
        urlAsset.cancelLoading()
    }
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !stopped else {
            request.finishLoading(with: CancellationError())
            return false
        }
        guard requests.count < 8 else {
            request.finishLoading(with: ClientError.invalid("Too many concurrent video requests. Retry playback."))
            return false
        }
        let id = ObjectIdentifier(request)
        requests[id] = Task { [weak self] in
            guard let self else { return }
            defer { requests.removeValue(forKey: id) }
            do {
                if let info = request.contentInformationRequest {
                    // Probe actual authorized range support before advertising seekability.
                    _ = try await MediaRange.fetch(asset, offset: 0, length: Int(min(asset.size, 2)), api: api)
                    info.contentType = UTType(mimeType: asset.mediaType)?.identifier ?? UTType.movie.identifier
                    info.contentLength = asset.size
                    info.isByteRangeAccessSupported = true
                }
                if let data = request.dataRequest {
                    var offset = max(data.requestedOffset, data.currentOffset)
                    let end =
                        data.requestsAllDataToEndOfResource
                        ? asset.size : min(asset.size, data.requestedOffset + Int64(data.requestedLength))
                    while offset < end {
                        try Task.checkCancellation()
                        let length = Int(min(Int64(MediaRange.maximumLength), end - offset))
                        let chunk = try await MediaRange.fetch(asset, offset: offset, length: length, api: api)
                        guard !stopped, !request.isCancelled else { throw CancellationError() }
                        data.respond(with: chunk)
                        offset += Int64(chunk.count)
                    }
                }
                if !request.isCancelled { request.finishLoading() }
            } catch {
                if !request.isCancelled { request.finishLoading(with: error) }
                if !stopped, !(error is CancellationError) { onError?(error) }
            }
        }
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        requests.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }
}
