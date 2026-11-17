import Photos
import SwiftUI

struct MediaThumbnail: View {
    let item: LocalMediaItem
    let manager: PHImageManager
    var upload: UploadItem?

    var body: some View {
        PhotoImageView(item: item, manager: manager, thumbnail: true)
            .overlay {
                if let upload, upload.phase != .succeeded, upload.phase != .failed, let progress = upload.progress {
                    UploadProgressSector(fraction: progress).fill(.black.opacity(0.45))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                if item.isLivePhoto {
                    Image(systemName: "livephoto").font(.caption.weight(.semibold))
                        .padding(5).background(.black.opacity(0.55), in: Capsule()).padding(4)
                        .foregroundStyle(.white)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Image(systemName: badge).font(.caption2.weight(.semibold))
                    .padding(6).foregroundStyle(.white)
            }
            .overlay(alignment: .bottomTrailing) {
                if item.kind == .video {
                    Group {
                        if item.duration > 0 {
                            Text(LocalMediaItem.playbackTime(item.duration)).monospacedDigit()
                        } else {
                            Image(systemName: "play.fill")
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.7), in: Capsule())
                    .foregroundStyle(.white).padding(5)
                }
            }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.isLivePhoto ? "Live Photo" : item.kind == .video ? "Video" : "Photo")
            .accessibilityValue(upload?.feedback ?? "In Photos")
    }

    private var badge: String {
        if upload?.phase == .succeeded { return "checkmark.icloud" }
        if upload?.phase == .failed { return "exclamationmark.triangle.fill" }
        return upload == nil ? "iphone" : "arrow.up.circle"
    }
}
