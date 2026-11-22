import Photos
import SwiftUI

struct UploadRow: View {
    let item: UploadItem
    let manager: PHImageManager
    let viewError: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MediaThumbnail(item: item.localPreview, manager: manager, upload: item)
                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.filename).font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.feedback).font(.footnote.weight(.medium))
                    .foregroundStyle(item.phase == .failed ? Color.red : MediaStyle.secondary)
                    .accessibilityIdentifier("uploads.status.\(item.id.uuidString)")
                HStack(spacing: 8) {
                    if let bytes = item.totalBytes {
                        Text(bytes, format: .byteCount(style: .file))
                    }
                    Text(item.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                }
                .font(.caption).foregroundStyle(MediaStyle.secondary)
                if item.phase == .failed {
                    Button("View error", action: viewError)
                        .font(.footnote.weight(.semibold)).frame(minHeight: 44)
                        .accessibilityIdentifier("uploads.error.\(item.id.uuidString)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}
