import AVKit
import PhotosUI
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var tab = 0
    var body: some View {
        Group {
            if model.signedIn && !model.needsOnboarding && !model.needsReauthentication {
                TabView(selection: $tab) {
                    GalleryView(model: model)
                        .tabItem { Label("Photos", systemImage: "square.grid.2x2") }.tag(0)
                    NavigationStack { SearchView(model: model) }
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(1)
                    NavigationStack { PeopleView(model: model) }
                        .tabItem { Label("People", systemImage: "person.2") }.tag(2)
                    NavigationStack { CollectionsView(model: model) }
                        .tabItem { Label("Albums", systemImage: "rectangle.stack") }.tag(3)
                }
                .id(model.mediaGeneration)
                .onChange(of: model.mediaGeneration) { _, _ in tab = 0 }
            } else {
                OnboardingView(model: model)
            }
        }
        .alert("Nephos", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
        .sheet(isPresented: $model.showCleanupConfirmation) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Label("Remove from Photos, not just this phone", systemImage: "exclamationmark.triangle.fill")
                            .font(.title2)
                        Text(
                            "Up to 10 verified, unedited single-resource items will be checked again before iOS asks for removal. Live Photos, RAW pairs, edited and unsupported resources are blocked."
                        )
                        Text(
                            "If you use iCloud Photos or a shared library, deletion can propagate to iCloud and other devices or people. This is not local-only eviction."
                        )
                        Text(
                            "Nephos will request a fresh 30-day application retention hold. The server has a single-volume copy, NOT an independent backup. Disk failure, ransomware, or operator deletion can still lose it."
                        )
                        Text(
                            "You must also approve the iOS Photos dialog. Recently Deleted may keep using space. The server and iOS confirmation are not an atomic transaction."
                        )
                        Button("Verify originals and request Photos removal", role: .destructive) {
                            model.showCleanupConfirmation = false
                            Task { await model.removeConfirmedCopies() }
                        }.buttonStyle(.borderedProminent).disabled(model.isRunning)
                    }.padding()
                }
                .navigationTitle("Confirm removal")
                .toolbar { Button("Cancel") { model.showCleanupConfirmation = false } }
            }
        }
    }
}

struct GalleryView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var datePicker = false
    @State private var filter: MediaFilter = .all
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var shareSelection: ShareSelection?
    private var refreshTrigger: GalleryRefreshTrigger {
        GalleryRefreshTrigger(
            active: scenePhase == .active, connected: NetworkPolicy.shared.isConnected,
            ready: model.signedIn && !model.needsReauthentication && !model.needsOnboarding,
            epoch: model.epoch, library: model.ledger.selectedLibraryID)
    }
    private var progress: BackupProgress {
        BackupProgress(ledger: model.ledger, library: model.ledger.selectedLibraryID)
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                if let library = model.selectedLibrary {
                                    Text(library.name).font(.subheadline).foregroundStyle(.secondary)
                                }
                                if let count = model.retainedGallery?.snapshot.totalCount {
                                    Text("\(count) items").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            NavigationLink {
                                BackupView(model: model)
                            } label: {
                                Label(
                                    model.ledger.settings.backupPaused == true
                                        ? "Paused"
                                        : progress.pending > 0 ? "\(progress.pending) pending" : "Backup",
                                    systemImage: "cloud"
                                )
                                .font(.caption.bold()).padding(10)
                                .background(NephosStyle.accent.opacity(0.1), in: Capsule())
                            }
                        }
                        Picker("Media type", selection: $filter) {
                            ForEach(MediaFilter.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                        if model.galleryIsStale || model.galleryRefreshError != nil {
                            Label(
                                NetworkPolicy.shared.isConnected
                                    ? "Gallery updates are delayed. Retrying automatically."
                                    : "Offline. The gallery will update when reconnected.",
                                systemImage: "arrow.clockwise"
                            )
                            .font(.caption).foregroundStyle(.orange)
                        }
                        if model.ledger.selectedLibraryID == nil {
                            LibrarySelector(model: model)
                        } else if model.gallery.items.filter({ filter.includes($0) }).isEmpty && !model.isLoadingGallery
                        {
                            ContentUnavailableView(
                                "No matching media loaded", systemImage: "photo",
                                description: Text(
                                    "New photos appear automatically. Try another filter or load older items."))
                        }
                        ForEach(MediaDay.groups(model.gallery.items, filter: filter)) { day in
                            VStack(alignment: .leading, spacing: 9) {
                                Text(day.date?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown date")
                                    .font(.headline)
                                LazyVGrid(columns: NephosStyle.columns, spacing: 3) {
                                    ForEach(day.assets) { asset in
                                        Group {
                                            if selecting {
                                                Button {
                                                    if selected.contains(asset.id) {
                                                        selected.remove(asset.id)
                                                    } else {
                                                        selected.insert(asset.id)
                                                    }
                                                } label: {
                                                    AssetTile(asset: asset, model: model)
                                                        .overlay(alignment: .topTrailing) {
                                                            Image(
                                                                systemName: selected.contains(asset.id)
                                                                    ? "checkmark.circle.fill" : "circle"
                                                            )
                                                            .foregroundStyle(.white).shadow(radius: 2).padding(5)
                                                        }
                                                }.disabled(
                                                    asset.sharedBy != nil || model.selectedLibrary?.isReadOnly == true)
                                            } else {
                                                NavigationLink {
                                                    OriginalView(asset: asset, model: model)
                                                } label: {
                                                    AssetTile(asset: asset, model: model)
                                                }
                                            }
                                        }
                                        .id(asset.id)
                                        .background(
                                            GeometryReader { geometry in
                                                Color.clear.preference(
                                                    key: GalleryPositions.self,
                                                    value: [asset.id: geometry.frame(in: .named("gallery")).minY])
                                            })
                                    }
                                }
                            }
                        }
                        if model.isLoadingGallery { ProgressView("Loading gallery…").frame(maxWidth: .infinity) }
                        if model.gallery.nextCursor != nil {
                            Button("Load older photos and videos") { Task { await model.loadGallery() } }
                                .buttonStyle(.bordered).frame(maxWidth: .infinity)
                        }
                        if model.gallery.nextCursor != nil {
                            Text("Filters apply to up to 300 loaded items.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                }
                .coordinateSpace(name: "gallery")
                .onPreferenceChange(GalleryPositions.self) { positions in
                    let displayed = model.gallery.items.filter { filter.includes($0) }
                    if let first = displayed.first(where: { positions[$0.id].map { $0 >= -40 } == true }) {
                        model.galleryAtTop = first.id == displayed.first?.id
                        if model.visibleAnchor != first.id { model.rememberAnchor(first.id) }
                    }
                }
                .onChange(of: model.gallery.items.map(\.id)) { _, _ in
                    selected.formIntersection(Set(model.gallery.items.map(\.id)))
                    if let id = model.scrollTarget ?? model.visibleAnchor { proxy.scrollTo(id, anchor: .top) }
                }
                .refreshable { await model.loadGallery(reset: true) }
                .navigationTitle("Library")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Menu {
                            Button(selecting ? "Cancel selection" : "Select photos") {
                                selected = []
                                selecting.toggle()
                            }.disabled(model.selectedLibrary == nil || model.selectedLibrary?.isReadOnly == true)
                            Button("Newest") { Task { await model.loadGallery(reset: true, newest: true) } }
                            Button("Jump to date") { datePicker = true }.disabled(model.retainedGallery == nil)
                            if let error = model.galleryRefreshError {
                                Button("Update details") { model.message = error }
                            }
                        } label: {
                            Label("Library actions", systemImage: "ellipsis.circle")
                        }
                        NavigationLink {
                            SettingsView(model: model)
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if selecting {
                        Button("Share \(selected.count) selected") {
                            if let library = model.selectedLibrary {
                                shareSelection = ShareSelection(library: library, assets: Array(selected))
                            }
                        }
                        .buttonStyle(.borderedProminent).disabled(selected.isEmpty)
                        .padding().frame(maxWidth: .infinity).background(.regularMaterial)
                    }
                }
                .sheet(isPresented: $datePicker) { TimelineView(model: model) }
                .sheet(item: $shareSelection) { selection in
                    NavigationStack { ShareComposer(model: model, selection: selection) }
                }
                .task {
                    if model.ledger.selectedLibraryID == nil, let library = model.libraries.first {
                        await model.selectLibrary(library.id)
                    } else if !model.gallery.hasLoaded {
                        await model.loadGallery(reset: true)
                    }
                }
                .task(id: refreshTrigger) {
                    guard refreshTrigger.enabled else { return }
                    var failures = 0
                    while !Task.isCancelled {
                        await model.loadGallery(reset: true, notifyErrors: false, automatic: true)
                        failures = model.galleryRefreshError == nil ? 0 : failures + 1
                        do {
                            try await Task.sleep(for: .seconds(GalleryRefreshPolicy.delay(failures: failures)))
                        } catch { return }
                    }
                }
            }
        }
    }
}

struct GalleryPositions: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] { [:] }
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct TimelineView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if let error = model.timelineError { Text(error).foregroundStyle(.red) }
                if let year = model.timelineYear {
                    Button("Browse all of \(year)") {
                        Task {
                            await model.jump(to: String(year))
                            dismiss()
                        }
                    }
                    if let month = model.timelineMonth {
                        Button("Browse \(year)-\(String(format: "%02d", month))") {
                            Task {
                                await model.jump(to: String(format: "%04d-%02d", year, month))
                                dismiss()
                            }
                        }
                    }
                }
                ForEach(model.timeline) { bucket in
                    Button {
                        Task {
                            let components = bucket.date.split(separator: "-").compactMap { Int($0) }
                            if model.timelineYear == nil, let year = components.first {
                                await model.loadTimeline(year: year)
                            } else if model.timelineMonth == nil, components.count >= 2 {
                                await model.loadTimeline(year: components[0], month: components[1])
                            } else {
                                await model.jump(to: bucket.date)
                                dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            Text(
                                String(
                                    bucket.date.prefix(
                                        model.timelineYear == nil ? 4 : (model.timelineMonth == nil ? 7 : 10))))
                            Spacer()
                            Text("\(bucket.count)").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                        }
                    }
                }
            }
            .navigationTitle("Jump to capture date")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Years") { Task { await model.loadTimeline() } } }
            }
            .task { await model.loadTimeline() }
        }
    }
}

struct LibrarySelector: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading) {
            Picker(
                "Library",
                selection: Binding(
                    get: { model.ledger.selectedLibraryID },
                    set: { id in
                        if let id { Task { await model.selectLibrary(id) } }
                    })
            ) {
                Text("Select a library").tag(Optional<UUID>.none)
                ForEach(model.libraries) {
                    Text($0.name + ($0.isReadOnly ? " (shared)" : "")).tag(Optional($0.id))
                }
            }.disabled(model.isRunning)
            if model.libraryCursor != nil {
                Button("Load more libraries") {
                    Task { do { try await model.loadLibraries() } catch { model.handle(error) } }
                }
            }
        }
    }
}

struct AssetTile: View {
    let asset: Asset
    let model: AppModel
    @State private var image: UIImage?
    @State private var unavailable = false
    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    Rectangle().fill(.quaternary)
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: asset.isVideo ? "video" : "photo").font(.title).foregroundStyle(.secondary)
                    }
                    if asset.isVideo {
                        Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white).shadow(radius: 3)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if asset.sharedBy != nil {
                    Image(systemName: "person.2.fill").font(.caption2).padding(5)
                        .foregroundStyle(.white).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                        .padding(4)
                }
            }
            .overlay(alignment: .bottom) {
                if unavailable {
                    Text("Preview unavailable").font(.caption2).padding(3)
                        .background(.regularMaterial).frame(maxWidth: .infinity)
                }
            }
            .clipped().clipShape(RoundedRectangle(cornerRadius: 3))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(asset.isVideo ? "Video" : "Photo"), \(asset.fileName)\(asset.sharedBy == nil ? "" : ", shared with you")"
            )
            .task(id: "\(model.mediaGeneration)/\(asset.id)") {
                guard let api = model.api, let account = model.account else { return }
                let generation = model.mediaGeneration
                image = nil
                unavailable = false
                do {
                    let loaded = try await MediaCache.shared.preview(asset, api: api, account: account)
                    guard model.account == account, generation == model.mediaGeneration, !Task.isCancelled else {
                        return
                    }
                    image = loaded
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError), generation == model.mediaGeneration else {
                        return
                    }
                    unavailable = true
                    if AppModel.accessDenied(error) {
                        model.clearGalleryAccess()
                        model.handle(error)
                    }
                }
            }
    }
}

struct OriginalView: View {
    let asset: Asset
    let model: AppModel
    @State private var file: URL?
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var rangedPlayer: RangedPlayer?
    @State private var manifest: ResourceManifest?
    @State private var manifestLoaded = false
    @State private var exported: VerifiedExport?
    @State private var exportTask: Task<Void, Never>?
    @State private var exporting = false
    @State private var sharing = false
    @State private var outcome: String?
    @State private var failure: String?
    @State private var loading = true
    @State private var retry = 0
    @State private var showingDetails = false
    @State private var showingPeople = false
    @State private var shareSelection: ShareSelection?
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(width: geometry.size.width * zoom, height: geometry.size.height * zoom)
                            .onTapGesture(count: 2) {
                                zoom = zoom == 1 ? 2 : 1
                                lastZoom = zoom
                            }
                            .gesture(
                                MagnifyGesture().onChanged { value in
                                    zoom = min(4, max(1, lastZoom * value.magnification))
                                }.onEnded { _ in lastZoom = zoom }
                            )
                            .accessibilityLabel(asset.fileName)
                    }
                }
            } else if let player {
                VideoPlayer(player: player)
            } else if let failure {
                VStack {
                    ContentUnavailableView(
                        "Preview unavailable", systemImage: "exclamationmark.triangle", description: Text(failure))
                    Button("Retry") { retry += 1 }
                }.foregroundStyle(.white)
            } else {
                ProgressView("Loading preview…").tint(.white).foregroundStyle(.white)
            }
        }
        .navigationTitle(GalleryDates.parse(asset.createdAt)?.formatted(date: .abbreviated, time: .omitted) ?? "Photo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let owner = asset.sharedBy {
                    Label("Shared by \(owner)", systemImage: "person.2").font(.caption)
                }
                if exporting { ProgressView("Verifying originals…") }
                if let outcome { Text(outcome).font(.caption) }
                HStack {
                    if !asset.isVideo {
                        Button {
                            showingPeople = true
                        } label: {
                            Label("People", systemImage: "person.2")
                        }
                        Spacer()
                    }
                    Menu {
                        if asset.sharedBy == nil {
                            Button("Share with a known user") {
                                shareSelection = ShareSelection(
                                    library: model.libraries.first(where: { $0.id == asset.libraryId })
                                        ?? Library(id: asset.libraryId, name: "Library"),
                                    assets: [asset.id])
                            }
                        }
                        Button("Export all originals") { prepareExport(restore: false) }
                            .disabled(exporting || !manifestLoaded)
                        Button("Save back to Photos") { prepareExport(restore: true) }
                            .disabled(exporting || !manifestLoaded || manifest?.restoreSupported == false)
                    } label: {
                        Label("Share or export", systemImage: "square.and.arrow.up")
                    }
                    Spacer()
                    Button {
                        showingDetails = true
                    } label: {
                        Label("Info", systemImage: "info.circle")
                    }
                }.font(.title3).labelStyle(.iconOnly).buttonStyle(.bordered)
            }.padding().foregroundStyle(.white).background(.black)
        }
        .task(id: retry) {
            guard let api = model.api else { return }
            let version = model.epoch
            failure = nil
            do {
                manifest = try await api.resources(asset)
                guard version == model.epoch else { return }
                manifestLoaded = true
                if asset.isVideo {
                    rangedPlayer?.stop()
                    let ranged = RangedPlayer(asset: asset, api: api)
                    ranged.onError = { error in
                        failure = error.localizedDescription
                        player?.pause()
                        player = nil
                        if AppModel.accessDenied(error) {
                            model.clearGalleryAccess()
                            model.handle(error)
                        }
                    }
                    rangedPlayer = ranged
                    let item = AVPlayerItem(asset: ranged.urlAsset)
                    item.preferredForwardBufferDuration = 5
                    player = AVPlayer(playerItem: item)
                } else {
                    guard let account = model.account else { throw ClientError.signedOut }
                    let pixels = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale
                    let preview = try await MediaCache.shared.preview(
                        asset, api: api, account: account, size: pixels <= 1280 ? .screen : .detail)
                    guard version == model.epoch else { return }
                    image = preview
                }
            } catch {
                if !(error is CancellationError) { failure = error.localizedDescription }
                if let file {
                    try? FileManager.default.removeItem(at: file)
                    self.file = nil
                }
                if AppModel.accessDenied(error) {
                    model.clearGalleryAccess()
                    model.handle(error)
                }
            }
            loading = false
        }
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
            rangedPlayer?.stop()
            rangedPlayer = nil
            player?.pause()
            player = nil
            image = nil
            if let file {
                try? FileManager.default.removeItem(at: file)
                self.file = nil
            }
            if let exported {
                try? FileManager.default.removeItem(at: exported.directory)
                self.exported = nil
            }
        }
        .sheet(isPresented: $sharing) {
            if let exported { FileShareView(files: exported.shareFiles) }
        }
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                ScrollView { originalDetails.padding() }
                    .navigationTitle("Original details")
                    .toolbar { Button("Done") { showingDetails = false } }
            }
        }
        .sheet(isPresented: $showingPeople) {
            NavigationStack {
                PhotoPeopleView(model: model, asset: asset)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { showingPeople = false } }
                    }
            }
        }
        .sheet(item: $shareSelection) { selection in
            NavigationStack { ShareComposer(model: model, selection: selection) }
        }
    }
    private var originalDetails: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(asset.fileName).font(.headline).textSelection(.enabled)
            Text(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file))
            Text(
                asset.isVideo
                    ? "Playback uses authenticated ranges. Only a complete export verifies the original SHA-256."
                    : "You are viewing a resized preview. Export and restore retrieve the unchanged original.")
            if let manifest {
                Text("\(manifest.kind) · \(manifest.resources.count) original resources")
                if !manifest.restoreSupported {
                    Text(
                        "Edited/archive resources cannot be reconstructed accurately in Photos. Export preserves originals and their manifest; cleanup stays blocked."
                    )
                    .foregroundStyle(.orange)
                }
                Button("Verify complete server retention") {
                    exporting = true
                    let epoch = model.epoch
                    exportTask = Task {
                        defer { exporting = false }
                        do {
                            let result = try await model.verifyRetention(manifest)
                            guard epoch == model.epoch, !Task.isCancelled else { return }
                            outcome = result
                        } catch {
                            guard epoch == model.epoch else { return }
                            outcome = error.localizedDescription
                            model.handle(error)
                        }
                    }
                }.disabled(exporting)
            }
            if exporting { ProgressView("Verifying originals…") }
            if let outcome { Text(outcome) }
            Text(
                "Temporary exports are removed when you leave the viewer. Save them to Files or Photos to keep a copy. Server retention is not an independent backup."
            )
            .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func prepareExport(restore: Bool) {
        guard let api = model.api, !exporting else { return }
        exporting = true
        outcome = nil
        let version = model.epoch
        let mediaVersion = model.mediaGeneration
        exportTask = Task {
            defer { exporting = false }
            do {
                let result: VerifiedExport
                if let exported {
                    result = exported
                } else {
                    result = try await VerifiedExport.download(
                        asset: asset, manifest: manifest, api: api, root: model.viewerDirectory())
                }
                guard version == model.epoch, mediaVersion == model.mediaGeneration, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: result.directory)
                    return
                }
                exported = result
                if restore {
                    try await result.saveToPhotos()
                    outcome =
                        "Photos confirmed creation from the verified originals. Albums, favorites, and edit history are not restored."
                } else {
                    sharing = true
                }
            } catch {
                if !(error is CancellationError) {
                    outcome = error.localizedDescription
                    model.handle(error)
                }
                if AppModel.accessDenied(error) { model.clearGalleryAccess() }
            }
        }
    }
}

struct FileShareView: UIViewControllerRepresentable {
    let files: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: files, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct BackupView: View {
    @Bindable var model: AppModel
    @State private var picker = false
    @State private var options = false
    @State private var reviewCopiesAfterOptions = false
    @State private var selectedItem: BackupItem?
    @State private var selectAfterDetails = false
    private var canBackUp: Bool {
        model.selectedLibrary != nil && model.selectedLibrary?.isReadOnly != true
            && !model.needsReauthentication && model.ledger.settings.backupPaused != true
    }
    private func selectPhotos() {
        Task {
            await model.requestPhotos()
            picker = true
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    BackupStatusView(model: model)
                    Button {
                        Task { await model.setBackupPaused(model.ledger.settings.backupPaused != true) }
                    } label: {
                        Image(systemName: model.ledger.settings.backupPaused == true ? "play.fill" : "pause.fill")
                            .frame(width: 44, height: 44)
                            .background(.quaternary, in: Circle())
                    }
                    .accessibilityLabel(model.ledger.settings.backupPaused == true ? "Resume backup" : "Pause backup")
                    .disabled(model.selectedLibrary == nil || model.selectedLibrary?.isReadOnly == true)
                }
                if let notice = model.backupNotice {
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                }
                if model.needsReauthentication {
                    Button("Sign in to resume backup") { Task { await model.login() } }
                }
                if model.backupItems.isEmpty {
                    ContentUnavailableView {
                        Label("No photos queued", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("Select photos with + or enable automatic backup in settings.")
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(model.backupItems) { item in
                            Button {
                                selectedItem = item
                            } label: {
                                BackupPhotoTile(item: item, model: model)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("backup.item.\(item.id)")
                            .accessibilityLabel("\(item.name), \(item.status(active: model.isActive(item)))")
                            .accessibilityHint("Show backup details")
                        }
                    }
                    Text("Tap a photo for details").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }.padding(16)
        }
        .navigationTitle("Backup")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Select photos and videos", systemImage: "plus", action: selectPhotos)
                    .disabled(!canBackUp || model.isRunning)
                Menu {
                    Button("Backup settings", systemImage: "gearshape") { options = true }
                    Button("Back up now", systemImage: "arrow.clockwise") {
                        Task { await model.runBackup(ignoreBackoff: true) }
                    }.disabled(!canBackUp || model.isRunning)
                } label: {
                    Label("Backup options", systemImage: "ellipsis")
                }
            }
        }
        .sheet(isPresented: $picker) {
            NativePhotoPicker { identifiers, missing in
                picker = false
                if missing > 0 {
                    model.message = "\(missing) selection(s) are not accessible in Photos and were not imported."
                }
                Task { await model.importSelected(identifiers) }
            }
        }
        .sheet(
            isPresented: $options,
            onDismiss: {
                if reviewCopiesAfterOptions {
                    reviewCopiesAfterOptions = false
                    model.checkCleanup()
                }
            },
            content: {
                BackupOptionsView(model: model) {
                    reviewCopiesAfterOptions = true
                    options = false
                }
            }
        )
        .sheet(
            item: $selectedItem,
            onDismiss: {
                if selectAfterDetails {
                    selectAfterDetails = false
                    selectPhotos()
                }
            },
            content: { item in
                BackupItemDetails(model: model, id: item.id) { selectAfterDetails = true }
            }
        )
    }
}

struct BackupPhotoThumbnail: View {
    let source: SourceRevision
    let photos: PhotosLibrary
    @State private var image: UIImage?
    @State private var failure: String?
    var body: some View {
        Color(.secondarySystemBackground)
            .overlay {
                if let image {
                    GeometryReader { geometry in
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                    .accessibilityIdentifier("backup.thumbnail.loaded")
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                        .accessibilityLabel(failure ?? "Loading photo preview")
                }
            }
            .task(id: "\(source.localIdentifier)/\(source.modificationTime)") {
                image = nil
                failure = nil
                do {
                    let loaded = try await photos.thumbnail(source.localIdentifier)
                    try Task.checkCancellation()
                    image = loaded
                } catch {
                    if !Task.isCancelled { failure = error.localizedDescription }
                }
            }
            .onDisappear { image = nil }
    }
}

struct BackupPhotoTile: View {
    let item: BackupItem
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            BackupPhotoThumbnail(source: item.source, photos: model.photos)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if model.isActive(item), !item.isSaved {
                        ZStack {
                            Circle().fill(.black.opacity(0.4))
                            if let progress = item.progress(chunkSize: model.connection?.config.chunkSize ?? 0),
                                progress < 1
                            {
                                Circle().stroke(.white.opacity(0.3), lineWidth: 3).padding(5)
                                Circle().trim(from: 0, to: progress).stroke(
                                    .white, style: StrokeStyle(lineWidth: 3, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90)).padding(5)
                                Text("\(Int(progress * 100))%").font(.caption.bold()).foregroundStyle(.white)
                            } else {
                                ProgressView().tint(.white)
                            }
                        }.frame(width: 58, height: 58)
                            .accessibilityIdentifier("backup.circular-progress")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if item.isSaved || item.isStopped {
                        Image(systemName: item.isSaved ? "checkmark" : "exclamationmark")
                            .font(.caption.bold()).foregroundStyle(item.isSaved ? .green : .orange)
                            .padding(7).background(.regularMaterial, in: Circle()).padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 13))
            Text(item.status(active: model.isActive(item))).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

struct BackupItemDetails: View {
    let model: AppModel
    let id: UUID
    let selectCurrent: () -> Void
    @Environment(\.dismiss) private var dismiss
    private var item: BackupItem? { model.backupItem(id) }
    var body: some View {
        NavigationStack {
            ScrollView {
                if let item {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 15) {
                            BackupPhotoThumbnail(source: item.source, photos: model.photos)
                                .frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.status(active: model.isActive(item))).font(.headline)
                                Text(item.name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if item.diagnostic != nil || item.sourceChanged {
                            Text(item.recovery).foregroundStyle(.secondary)
                        } else {
                            Text(
                                item.isSaved
                                    ? "The complete original is saved on your server."
                                    : "This photo will finish automatically when backup can continue."
                            )
                            .foregroundStyle(.secondary)
                        }
                        if !item.isSaved {
                            if PhotosNetworkFailure.legacyCode(item.diagnostic) == 3164
                                && !model.ledger.settings.allowCellular
                            {
                                Button("Use cellular data") {
                                    var settings = model.ledger.settings
                                    settings.allowCellular = true
                                    model.setSettings(settings)
                                }.buttonStyle(.borderedProminent)
                            }
                            if item.sourceChanged {
                                Button("Select current version") {
                                    selectCurrent()
                                    dismiss()
                                }
                                .disabled(model.isRunning || model.selectedLibrary?.isReadOnly == true)
                            } else {
                                Button("Retry this item") {
                                    Task { await model.runBackup(ignoreBackoff: true, retryItem: id) }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(
                                    model.isRunning || model.needsReauthentication
                                        || model.selectedLibrary?.isReadOnly == true
                                        || model.ledger.settings.backupPaused == true)
                            }
                        }
                        DisclosureGroup("Technical details") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Item: \(item.id)")
                                if let error = item.diagnostic { Text(error) }
                                if let retry = item.group?.nextRetryAt { Text("Next attempt: \(retry.formatted())") }
                                ForEach(item.records) { record in
                                    Text(
                                        "\(record.fileName)\nUpload: \(record.id)\nState: \(record.phase.rawValue)\n\(record.receivedParts.count) parts acknowledged · \(ByteCountFormatter.string(fromByteCount: record.size, countStyle: .file))"
                                    )
                                    if let attempted = record.lastAttemptAt {
                                        Text("Last attempt: \(attempted.formatted())")
                                    }
                                    if let retry = record.nextRetryAt { Text("Next attempt: \(retry.formatted())") }
                                    if let error = record.error, error != item.diagnostic { Text(error) }
                                }
                            }.font(.caption).textSelection(.enabled)
                        }.font(.callout)
                    }.padding(24)
                }
            }
            .navigationTitle("Photo backup").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

struct BackupOptionsView: View {
    let model: AppModel
    let reviewCopies: () -> Void
    @Environment(\.dismiss) private var dismiss
    private func setting(_ key: WritableKeyPath<BackupSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.ledger.settings[keyPath: key] },
            set: {
                var settings = model.ledger.settings
                settings[keyPath: key] = $0
                model.setSettings(settings)
            })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Library") { LibrarySelector(model: model) }
                Section("Backup") {
                    Toggle("Automatic backup", isOn: setting(\.automaticBackup))
                    Toggle("Use cellular data", isOn: setting(\.allowCellular))
                    Text("Low Data Mode is respected. Background execution is scheduled by iOS.").font(.caption)
                }
                Section("Photos access") {
                    Text(model.photosStatus).font(.callout)
                    Button("Photos access") { Task { await model.requestPhotos() } }
                    Link("Open iOS Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                }
                Section("Phone-space cleanup") {
                    Text("Review verified copies. Nothing is removed without your confirmation.").font(.callout)
                    Button("Review verified phone copies", role: .destructive) {
                        if model.cleanupCandidates.isEmpty { model.checkCleanup() } else { reviewCopies() }
                    }
                    .disabled(model.isRunning)
                    if !model.cleanupReport.isEmpty { Text(model.cleanupReport).font(.caption) }
                }
                if let diagnostic = model.backupDiagnostic {
                    Section {
                        DisclosureGroup("Technical details") { Text(diagnostic).font(.caption).textSelection(.enabled) }
                    }
                }
            }
            .navigationTitle("Backup settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var cleanupOptIn = false
    @State private var signingOut = false
    private func setting(_ path: WritableKeyPath<BackupSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.ledger.settings[keyPath: path] },
            set: {
                var settings = model.ledger.settings
                settings[keyPath: path] = $0
                model.setSettings(settings)
            })
    }
    var body: some View {
        Group {
            Form {
                AppearancePicker()
                Section("Library") {
                    LibrarySelector(model: model)
                    NavigationLink("Backup and upload queue") { BackupView(model: model) }
                    NavigationLink("Manage shared access") { SharingListView(model: model, received: false) }
                }
                Section("Independent opt-ins") {
                    Toggle("Automatically back up accessible Photos", isOn: setting(\.automaticBackup))
                    Text(
                        "Existing/new allowed photos and videos are scanned in bounded batches while the app or iOS permits work. Limited access excludes other Photos. Open the app to ensure progress."
                    ).font(.caption)
                    Toggle(
                        "Automatically offer verified phone cleanup",
                        isOn: Binding(
                            get: { model.ledger.settings.automaticCleanup },
                            set: { enabled in
                                if enabled {
                                    cleanupOptIn = true
                                } else {
                                    var settings = model.ledger.settings
                                    settings.automaticCleanup = false
                                    model.setSettings(settings)
                                }
                            }))
                    Text(
                        "Independent of automatic backup. Never silent: a foreground warning and iOS consent are required."
                    ).font(.caption)
                    Toggle("Allow cellular / expensive upload networks", isOn: setting(\.allowCellular))
                    Text(
                        "Turning this off applies to new transfer tasks. An already-running system transfer may finish with its previous policy. Low Data Mode is not used for uploads."
                    ).font(.caption)
                }
                Section("Storage and safety") {
                    Text(
                        "Upload staging: 10 GiB total, one 4 MiB part at a time. Images: 512 MiB viewer budget. Videos: authenticated 512 KiB byte ranges, no whole-file cache. Complete exports: 10 GiB/free-space bounded, evicted on exit. Previews: 32 MiB target / 100 images. Gallery metadata: 300 items per account's selected library."
                    )
                    Text(
                        "Server retention protects application references, not independent copies. Photos deletion can propagate through iCloud and shared libraries. Recently Deleted may retain storage."
                    )
                    Button("Clear preview cache") { MediaCache.shared.clear() }
                    Link("Open iOS app settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                }
                Section("Account and server") {
                    if let connection = model.connection {
                        Text(connection.baseURL.absoluteString).textSelection(.enabled)
                        Text("Server: \(connection.config.serverId)").font(.caption)
                    }
                    Button("Sign out / change server", role: .destructive) { signingOut = true }.disabled(
                        model.isRunning)
                    Button("Sign in again to refresh authorization") { Task { await model.login() } }.disabled(
                        model.isRunning)
                    Text(
                        "Sign-out cancels system tasks and clears credentials, gallery, and viewer caches. Pending upload staging remains isolated by server and account, available only after that account signs in again."
                    ).font(.caption)
                }
            }
            .navigationTitle("Settings")
            .alert("Enable cleanup offers?", isPresented: $cleanupOptIn) {
                Button("Enable", role: .destructive) {
                    var settings = model.ledger.settings
                    settings.automaticCleanup = true
                    settings.cleanupWarningsAcknowledged = true
                    model.setSettings(settings)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Removal affects Photos, potentially iCloud and other devices. Server originals have a retention hold but only a single-volume copy. This does not enable automatic backup. You must approve each foreground removal and the iOS dialog."
                )
            }
            .confirmationDialog(
                "Sign out? Queued originals remain in account-isolated staging.", isPresented: $signingOut,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) {
                    Task { do { try await model.signOut() } catch { model.handle(error) } }
                }
            }
        }
    }
}

struct NativePhotoPicker: UIViewControllerRepresentable {
    let completion: ([String], Int) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 20
        config.filter = .any(of: [.images, .videos])
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: ([String], Int) -> Void
        init(completion: @escaping ([String], Int) -> Void) { self.completion = completion }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let identifiers = results.compactMap(\.assetIdentifier)
            completion(identifiers, results.count - identifiers.count)
        }
    }
}
