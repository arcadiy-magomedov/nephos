import SwiftUI

struct LibraryUploadProgress: View {
    let uploads: UploadModel

    var body: some View {
        if uploads.showsProgress, let batch = uploads.snapshot.batch {
            HStack(spacing: 4) {
                if batch.completedAt == nil {
                    Button {
                        Task { await uploads.togglePause() }
                    } label: {
                        Image(systemName: uploads.snapshot.paused ? "play.fill" : "pause.fill")
                            .font(.caption.weight(.semibold)).frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(uploads.snapshot.paused ? "Resume all uploads" : "Pause all uploads")
                    .accessibilityIdentifier("uploads.library.pauseResume")
                }
                NavigationLink(value: MediaRoute.uploads) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(caption(batch)).font(.caption).foregroundStyle(MediaStyle.secondary)
                            .multilineTextAlignment(.leading)
                        ProgressView(value: batch.progress)
                            .tint(MediaStyle.uploadGreen)
                            .accessibilityLabel("Files backed up")
                            .accessibilityValue("\(batch.succeeded) of \(batch.total)")
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Uploads")
                .accessibilityIdentifier("uploads.library.progress")
            }
        }
    }

    private func caption(_ batch: UploadBatch) -> String {
        let state: String
        if batch.completedAt != nil {
            state = "Uploaded"
        } else if uploads.snapshot.policy == .disabled {
            state = "Uploads disabled:"
        } else if uploads.snapshot.paused {
            state = "Paused:"
        } else if uploads.snapshot.scanning {
            return "Checking Photos..."
        } else {
            state = "Uploading"
        }
        let failures = batch.failed > 0 ? " · \(batch.failed) failed" : ""
        return "\(state) \(batch.succeeded) of \(batch.total) files\(failures)"
    }
}
