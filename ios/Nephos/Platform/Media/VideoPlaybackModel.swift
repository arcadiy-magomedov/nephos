import AVFoundation
import OSLog
import Observation
import Photos

@MainActor
@Observable
final class VideoPlaybackModel {
    let player = AVPlayer()
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var isLoading = true
    private(set) var error: String?
    var isMuted = true {
        didSet { player.isMuted = isMuted }
    }
    @ObservationIgnored private var request = PHInvalidImageRequestID
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemObserver: NSKeyValueObservation?
    @ObservationIgnored private var playbackObserver: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var audioActive = false

    init() {
        player.isMuted = true
        playbackObserver = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if request != PHInvalidImageRequestID { PHImageManager.default().cancelImageRequest(request) }
    }

    func load(_ item: LocalMediaItem) {
        stop()
        error = nil
        isLoading = true
        duration = item.duration
        position = 0
        let version = generation
        do {
            let asset = try LocalMediaLibrary.asset(item.id)
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            let handler: (AVPlayerItem?, [AnyHashable: Any]?) -> Void = { [weak self] playerItem, info in
                let message = (info?[PHImageErrorKey] as? Error)?.localizedDescription
                Task { @MainActor in
                    guard let self, self.generation == version else { return }
                    guard let playerItem else {
                        self.error = message ?? "Photos could not load this video. Check your connection and try again."
                        self.isLoading = false
                        return
                    }
                    self.install(playerItem)
                }
            }
            request = PHImageManager.default().requestPlayerItem(
                forVideo: asset, options: options, resultHandler: handler)
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                audioActive = true
                if position >= duration { seek(to: 0) }
                player.play()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func seek(to seconds: TimeInterval) {
        position = min(max(0, seconds), duration)
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
    }

    func pause() {
        player.pause()
        guard audioActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioActive = false
        } catch {
            Logger(subsystem: "app.nephos.ios", category: "VideoPlayback")
                .warning("Unable to release the audio session: \(error.localizedDescription, privacy: .private)")
        }
    }

    func stop() {
        generation = UUID()
        pause()
        if request != PHInvalidImageRequestID { PHImageManager.default().cancelImageRequest(request) }
        request = PHInvalidImageRequestID
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        itemObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    private func install(_ item: AVPlayerItem) {
        let version = generation
        itemObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let failure = item.error?.localizedDescription
            let ready = item.status == .readyToPlay
            let failed = item.status == .failed
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.isLoading = !ready && !failed
                if failed { self.error = failure ?? "This video cannot be played." }
            }
        }
        player.replaceCurrentItem(with: item)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                guard let self, self.generation == version, seconds.isFinite else { return }
                self.position = max(0, seconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        }
    }
}
