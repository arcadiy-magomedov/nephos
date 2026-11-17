import SwiftUI

struct MediaViewer: View {
    let library: LocalMediaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var item: LocalMediaItem
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var error: String?
    @State private var share: LocalMediaExport?
    @State private var shareDirectory: URL?
    @State private var shareTask: Task<Void, Never>?
    @State private var preparingShare = false

    init(item: LocalMediaItem, library: LocalMediaLibrary) {
        self.library = library
        _item = State(initialValue: item)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if item.kind == .video {
                MediaVideoView(item: item, navigate: navigate).id(item)
            } else if item.isLivePhoto {
                MediaLivePhotoView(item: item, library: library, navigate: navigate).id(item)
            } else {
                ZoomablePhotoView(item: item, manager: library.images, navigate: navigate).id(item)
            }
        }
        .background(MediaStyle.background)
        .foregroundStyle(MediaStyle.text)
        .tint(MediaStyle.accent)
        .safeAreaInset(edge: .bottom, spacing: 0) { shareButton }
        .overlay {
            if deleting { ProgressView("Deleting from Photos").padding().background(.regularMaterial, in: Capsule()) }
        }
        .sheet(item: $share, onDismiss: clearShare) { export in
            MediaShareSheet(files: export.files) { share = nil }
        }
        .alert(
            "Couldn't complete the action",
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
        .onChange(of: library.items) { _, _ in
            guard !deleting else { return }
            if !library.contains(item) {
                dismiss()
            } else if let updated = library.items.first(where: { $0.id == item.id }) {
                item = updated
            }
        }
        .onDisappear { shareTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button("Back to library", systemImage: "chevron.left") { dismiss() }
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .background(MediaStyle.surface, in: Circle())
                .accessibilityIdentifier("viewer.back")
            VStack(spacing: 4) {
                if let date = item.capturedAt {
                    Text(date, format: .dateTime.day().month(.wide).year()).font(.headline)
                    Text(date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(MediaStyle.secondary)
                } else {
                    Text("Date unknown").font(.headline)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            Menu {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .disabled(!library.canDelete(item))
            } label: {
                Label("Media options", systemImage: "ellipsis").labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .background(MediaStyle.surface, in: Circle())
            }
            .disabled(deleting || preparingShare)
            .accessibilityIdentifier("viewer.options")
            .alert("Delete media?", isPresented: $confirmDelete) {
                Button("Delete from Photos", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Deleting from Photos can also delete this item from iCloud and other devices. Any completed Nephos backup is kept. Check Uploads before deleting your only local copy."
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var shareButton: some View {
        VStack(spacing: 4) {
            Button {
                if preparingShare { shareTask?.cancel() } else { prepareShare() }
            } label: {
                VStack(spacing: 4) {
                    ZStack {
                        Circle().fill(MediaStyle.surface).frame(width: 44, height: 44)
                        if preparingShare {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.up").font(.title3)
                        }
                    }
                    Text(preparingShare ? "Cancel sharing" : item.isLivePhoto ? "Share original files" : "Share").font(
                        .caption)
                }
            }
            .disabled(deleting)
            .accessibilityIdentifier("viewer.share")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12).padding(.bottom, 12)
        .background(MediaStyle.background)
    }

    private func navigate(_ direction: Int) {
        guard !deleting, !preparingShare, let next = library.neighbor(of: item, offset: direction) else { return }
        item = next
    }

    private func delete() {
        guard !deleting else { return }
        deleting = true
        let next = library.neighbor(of: item, offset: 1) ?? library.neighbor(of: item, offset: -1)
        Task { @MainActor in
            defer { deleting = false }
            do {
                if try await library.delete(item) {
                    if let next, library.contains(next) { item = next } else { dismiss() }
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func prepareShare() {
        preparingShare = true
        let selected = item
        shareTask = Task { @MainActor in
            defer {
                preparingShare = false
                shareTask = nil
            }
            do {
                let export = try await LocalMediaExport.prepare(selected)
                shareDirectory = export.directory
                share = export
            } catch {
                if !AuthSession.isCancelled(error) { self.error = error.localizedDescription }
            }
        }
    }

    private func clearShare() {
        if let shareDirectory { LocalMediaExport.remove(shareDirectory) }
        shareDirectory = nil
    }
}
