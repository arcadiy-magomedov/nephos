import AVKit
import SwiftUI

struct MediaVideoView: View {
    let item: LocalMediaItem
    let navigate: (Int) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var playback = VideoPlaybackModel()
    @State private var fullscreen = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                PlayerSurface(player: playback.player)
                    .aspectRatio(item.aspectRatio, contentMode: .fit)
                    .allowsHitTesting(false)
                if let error = playback.error {
                    ContentUnavailableView {
                        Label("Couldn't play video", systemImage: "video.slash")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { playback.load(item) }.buttonStyle(.bordered)
                    }
                } else if playback.isLoading {
                    ProgressView().accessibilityLabel("Loading video")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 30).onEnded { value in
                    if abs(value.translation.width) > 60,
                        abs(value.translation.width) > abs(value.translation.height) * 1.3
                    {
                        navigate(value.translation.width < 0 ? 1 : -1)
                    }
                }
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Video")
            .accessibilityAction(named: "Next item") { navigate(1) }
            .accessibilityAction(named: "Previous item") { navigate(-1) }
            controls
        }
        .task(id: item.id) {
            if playback.player.currentItem == nil { playback.load(item) }
        }
        .onDisappear {
            if !fullscreen { playback.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playback.pause() }
        }
        .fullScreenCover(isPresented: $fullscreen) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                VideoPlayer(player: playback.player).ignoresSafeArea()
                Button("Close full screen", systemImage: "xmark") { fullscreen = false }
                    .labelStyle(.iconOnly)
                    .frame(width: 48, height: 48)
                    .background(.black.opacity(0.7), in: Circle())
                    .foregroundStyle(.white).padding(16)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                Text(LocalMediaItem.playbackTime(playback.position))
                Spacer()
                Text(LocalMediaItem.playbackTime(playback.duration))
            }
            .font(.caption).monospacedDigit().foregroundStyle(MediaStyle.secondary)
            Slider(
                value: Binding(get: { playback.position }, set: { playback.seek(to: $0) }),
                in: 0...max(1, playback.duration)
            )
            .accessibilityLabel("Playback position")
            .accessibilityValue(LocalMediaItem.playbackTime(playback.position))
            .disabled(playback.isLoading || playback.error != nil)
            HStack(spacing: 20) {
                control(
                    playback.isMuted ? "Unmute" : "Mute", icon: playback.isMuted ? "speaker.slash" : "speaker.wave.2"
                ) {
                    playback.isMuted.toggle()
                }
                control(playback.isPlaying ? "Pause" : "Play", icon: playback.isPlaying ? "pause.fill" : "play.fill") {
                    playback.togglePlayback()
                }
                control("Full screen", icon: "arrow.up.left.and.arrow.down.right") { fullscreen = true }
            }
            .disabled(playback.isLoading || playback.error != nil)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    private func control(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).labelStyle(.iconOnly)
                .frame(width: 48, height: 48)
                .background(MediaStyle.surface, in: Circle())
        }
    }
}
