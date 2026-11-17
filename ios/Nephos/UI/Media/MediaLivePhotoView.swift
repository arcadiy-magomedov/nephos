import SwiftUI

struct MediaLivePhotoView: View {
    let item: LocalMediaItem
    let library: LocalMediaLibrary
    let navigate: (Int) -> Void
    @State private var playRequest = 0
    @State private var error: String?

    var body: some View {
        ZStack {
            PhotoImageView(item: item, manager: library.images)
            LivePhotoPlaybackView(item: item, playRequest: playRequest) { error = $0 }
        }
        .overlay(alignment: .topLeading) {
            Label("LIVE", systemImage: "livephoto")
                .font(.caption.weight(.semibold)).padding(8)
                .background(.regularMaterial, in: Capsule()).padding(12)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let error {
                    Text(error).font(.footnote).padding(10).background(
                        .regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    Button("Previous", systemImage: "chevron.left") { navigate(-1) }
                    Spacer()
                    Button("Play Live Photo", systemImage: "livephoto.play") { playRequest += 1 }
                    Spacer()
                    Button("Next", systemImage: "chevron.right") { navigate(1) }
                }
                .labelStyle(.iconOnly).buttonStyle(.bordered)
                .controlSize(.large).padding(12)
            }
        }
        .accessibilityLabel("Live Photo")
        .accessibilityHint("Touch and hold to play.")
        .accessibilityAction(named: "Play Live Photo") { playRequest += 1 }
    }
}
