import Photos
import SwiftUI

struct UploadsView: View {
    let uploads: UploadModel
    private let images = MediaImageCache.manager
    @State private var showingError = false
    @State private var failedItem: UploadItem?

    var body: some View {
        List {
            Section {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        pauseButton
                        Spacer(minLength: 8)
                        retryButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        pauseButton
                        retryButton
                    }
                }
                if let message = uploads.message ?? uploads.snapshot.notice {
                    Text(message).font(.footnote).foregroundStyle(MediaStyle.secondary)
                }
                if uploads.snapshot.policy == .disabled {
                    NavigationLink("Automatic upload is disabled", value: MediaRoute.settings)
                } else if uploads.snapshot.policy == .wiFiOnly {
                    Label("Wi-Fi only", systemImage: "wifi").font(.footnote)
                }
            }
            results("Completed successfully", count: uploads.snapshot.succeededCount, items: uploads.snapshot.succeeded)
            results("Failed", count: uploads.snapshot.failedCount, items: uploads.snapshot.failed)
            results("In progress / Scheduled", count: uploads.snapshot.pendingCount, items: uploads.snapshot.pending)
        }
        .scrollContentBackground(.hidden)
        .background(MediaStyle.background).foregroundStyle(MediaStyle.text).tint(MediaStyle.accent)
        .navigationTitle("Uploads").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .refreshable { await uploads.backgroundCheck() }
        .alert("Upload failed", isPresented: $showingError, presenting: failedItem) { _ in
            Button("Close", role: .cancel) {}
        } message: { item in
            Text(
                "\(item.filename)\n\n\(item.error ?? "The original could not be uploaded.")\n\nResolve the issue, then use Retry failed. The item has not been marked as backed up."
            )
        }
        .accessibilityIdentifier("uploads.screen")
    }

    private var pauseButton: some View {
        Button(
            uploads.snapshot.paused ? "Resume all" : "Pause all",
            systemImage: uploads.snapshot.paused ? "play.fill" : "pause.fill"
        ) {
            Task { await uploads.togglePause() }
        }
        .frame(minHeight: 44).disabled(uploads.snapshot.pendingCount == 0)
    }

    private var retryButton: some View {
        Button("Retry failed", systemImage: "arrow.clockwise") {
            Task { await uploads.retryFailed() }
        }
        .frame(minHeight: 44).disabled(uploads.snapshot.failedCount == 0)
        .accessibilityIdentifier("uploads.retryFailed")
    }

    private func results(_ title: String, count: Int, items: [UploadItem]) -> some View {
        Section {
            if items.isEmpty {
                Text("No files").foregroundStyle(MediaStyle.secondary).font(.subheadline)
            } else {
                ForEach(items) { item in
                    UploadRow(item: item, manager: images) {
                        failedItem = item
                        showingError = true
                    }
                }
                if count > items.count {
                    Button("Show more (\(items.count) of \(count))") {
                        Task { await uploads.loadMoreHistory() }
                    }
                    .frame(minHeight: 44)
                }
            }
        } header: {
            Text("\(title) (\(count))")
        }
    }
}
