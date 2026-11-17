import Photos
import SwiftUI

struct PhotoImageView: View {
    let item: LocalMediaItem
    let manager: PHImageManager
    var thumbnail = false
    @Environment(\.displayScale) private var displayScale
    @State private var loader = PhotoImageLoader()
    @State private var retry = 0

    var body: some View {
        GeometryReader { geometry in
            let target = CGSize(
                width: min(4096, max(1, geometry.size.width * displayScale)),
                height: min(4096, max(1, geometry.size.height * displayScale)))
            ZStack {
                thumbnail ? MediaStyle.surface : MediaStyle.background
                if let image = loader.image {
                    if thumbnail {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                } else if let error = loader.error {
                    if thumbnail {
                        Image(systemName: "photo.badge.exclamationmark").foregroundStyle(MediaStyle.secondary)
                    } else {
                        ContentUnavailableView {
                            Label("Couldn't load photo", systemImage: "photo.badge.exclamationmark")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Retry") { retry += 1 }.buttonStyle(.bordered)
                        }
                    }
                } else {
                    ProgressView().tint(MediaStyle.secondary)
                        .accessibilityLabel("Loading photo")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .task(id: RequestKey(id: item.id, modifiedAt: item.modifiedAt, size: target, retry: retry)) {
                loader.load(item.id, size: target, thumbnail: thumbnail, manager: manager)
            }
        }
        .onDisappear { loader.cancel() }
    }

    private struct RequestKey: Equatable {
        let id: String
        let modifiedAt: Date?
        let size: CGSize
        let retry: Int
    }
}
