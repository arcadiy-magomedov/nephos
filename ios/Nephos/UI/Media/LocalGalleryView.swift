import Photos
import SwiftUI

@MainActor
struct LocalGalleryView: View {
    let session: SignInModel
    let signOut: () -> Void
    private let uploads = UploadModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var library: LocalMediaLibrary
    @State private var selected: LocalMediaItem?
    @State private var managingAccess = false

    init(session: SignInModel, library: LocalMediaLibrary? = nil, signOut: @escaping () -> Void) {
        self.session = session
        self.signOut = signOut
        _library = State(initialValue: library ?? LocalMediaLibrary())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    header
                    LibraryUploadProgress(uploads: uploads)
                }
                if !session.message.isEmpty { connectionNotice }
                if library.authorization == .limited {
                    HStack {
                        Text("Showing selected Photos").font(.subheadline)
                        Spacer()
                        Button("Manage") { managingAccess = true }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("gallery.manageAccess")
                    }
                    .foregroundStyle(MediaStyle.secondary)
                }
                filters
                if !library.hasAccess {
                    permissionState
                } else if library.items.isEmpty {
                    ContentUnavailableView(
                        library.filter == .videos ? "No videos" : library.filter == .photos ? "No photos" : "No media",
                        systemImage: "photo.on.rectangle",
                        description: Text("Photos and videos you allow Nephos to access will appear here.")
                    )
                    .padding(.top, 40)
                } else {
                    chronology
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .background(MediaStyle.background)
        .foregroundStyle(MediaStyle.text)
        .tint(MediaStyle.accent)
        .safeAreaInset(edge: .bottom, spacing: 0) { navigation }
        .background {
            LimitedPhotosPicker(isPresented: $managingAccess) { library.refresh() }
                .frame(width: 0, height: 0)
        }
        .fullScreenCover(item: $selected) { item in
            MediaViewer(item: item, library: library)
        }
        .task { library.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.refreshAuthorization() }
        }
        .refreshable { library.refresh() }
        .onChange(of: library.items) { _, _ in uploads.photosChanged() }
    }

    private var header: some View {
        HStack {
            Text("Library").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Spacer()
            Menu {
                if library.authorization == .limited {
                    Button("Manage Photos access", systemImage: "photo.badge.plus") { managingAccess = true }
                }
                NavigationLink("Uploads", value: MediaRoute.uploads)
                NavigationLink("Settings", value: MediaRoute.settings)
                Button(
                    "Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive, action: signOut)
            } label: {
                Label("Library options", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .frame(width: 48, height: 48)
                    .background(MediaStyle.surface, in: Circle())
            }
            .accessibilityIdentifier("gallery.options")
        }
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                filterButtons
            }
            .fixedSize(horizontal: true, vertical: false)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                filterButtons
            }
        }
    }

    @ViewBuilder
    private var filterButtons: some View {
        ForEach(LocalMediaLibrary.Filter.allCases, id: \.self) { filter in
            Button {
                library.select(filter)
            } label: {
                Text(filter.rawValue).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                    .background(
                        library.filter == filter ? MediaStyle.selected : MediaStyle.surface, in: Capsule()
                    )
                    .foregroundStyle(library.filter == filter ? MediaStyle.accent : MediaStyle.text)
            }
            .accessibilityAddTraits(library.filter == filter ? .isSelected : [])
            .accessibilityIdentifier("gallery.filter.\(filter.rawValue)")
        }
        Button {
        } label: {
            Text("Shared").font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                .background(MediaStyle.surface, in: Capsule())
        }
        .disabled(true)
        .accessibilityIdentifier("gallery.filter.Shared")
        .accessibilityHint("Shared media is not available in local-only mode.")
    }

    private var chronology: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(library.days) { day in
                VStack(alignment: .leading, spacing: 10) {
                    Text(dayTitle(day.id)).font(.headline).accessibilityAddTraits(.isHeader)
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 150 : 100), spacing: 2)
                        ],
                        spacing: 2
                    ) {
                        ForEach(day.items) { item in
                            Button {
                                selected = item
                            } label: {
                                Color.clear.aspectRatio(1, contentMode: .fit).overlay {
                                    MediaThumbnail(
                                        item: item, manager: library.images, upload: uploads.thumbnailItems[item.id])
                                }
                                .clipped()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                item.isLivePhoto
                                    ? "Live Photo"
                                    : item.kind == .video
                                        ? "Video, \(LocalMediaItem.playbackTime(item.duration))" : "Photo"
                            )
                            .accessibilityValue(
                                uploads.thumbnailItems[item.id]?.feedback
                                    ?? item.capturedAt?.formatted(date: .abbreviated, time: .shortened)
                                    ?? "Date unknown"
                            )
                            .accessibilityHint("Opens the media viewer.")
                            .accessibilityIdentifier("gallery.item.\(item.id)")
                            .onAppear {
                                uploads.watch(item.id)
                                if item.id == library.items.last?.id { library.loadMore() }
                            }
                            .onDisappear { uploads.unwatch(item.id) }
                        }
                    }
                }
            }
        }
        .id(library.filter)
    }

    private var permissionState: some View {
        ContentUnavailableView {
            Label("Your Photos in Nephos", systemImage: "photo.on.rectangle")
        } description: {
            Text(
                library.authorization == .restricted
                    ? "Photos access is restricted on this device."
                    : """
                    Allow Photos access to browse your photos and videos. \
                    Automatic upload stays off until you enable it.
                    """
            )
        } actions: {
            if library.authorization == .notDetermined {
                Button {
                    Task { await library.requestAccess() }
                } label: {
                    Text("Allow Photos access").frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("gallery.allowAccess")
            } else if library.authorization != .restricted {
                Button(action: openSettings) {
                    Text("Open Settings").frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .padding(.top, 40)
    }
}

extension LocalGalleryView {
    private var connectionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.accessDenied ? "Access disabled" : "Couldn't connect to Nephos")
                .font(.subheadline.weight(.semibold))
            Text("Your local media is still available. \(session.message)").font(.footnote)
            HStack(spacing: 16) {
                Button("Retry connection") { Task { await session.restore() } }.frame(minHeight: 44)
                if session.accessDenied {
                    Button("Sign out", role: .destructive, action: signOut).frame(minHeight: 44)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MediaStyle.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var navigation: some View {
        HStack {
            navigationItem("Photos", icon: "square.grid.2x2", selected: true)
            navigationItem("Search", icon: "magnifyingglass")
            navigationItem("People", icon: "person.2")
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(MediaStyle.background)
        .overlay(alignment: .top) { Divider() }
    }

    private func navigationItem(_ title: String, icon: String, selected: Bool = false) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.caption)
            Capsule().fill(selected ? MediaStyle.accent : .clear).frame(width: 16, height: 3)
        }
        .frame(maxWidth: .infinity, minHeight: 54)
        .foregroundStyle(selected ? MediaStyle.accent : MediaStyle.secondary.opacity(0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(selected ? title : "\(title), not available in local-only mode")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func dayTitle(_ date: Date?) -> String {
        guard let date else { return "Date unknown" }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
