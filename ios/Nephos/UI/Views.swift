import AVKit
import PhotosUI
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    var body: some View {
        Group {
            if model.signedIn {
                TabView {
                    GalleryView(model: model).tabItem { Label("Gallery", systemImage: "photo.on.rectangle") }
                    BackupView(model: model).tabItem { Label("Backup", systemImage: "arrow.up.doc") }
                    SettingsView(model: model).tabItem { Label("Settings", systemImage: "gear") }
                }
                .id(model.mediaGeneration)
            } else {
                ConnectionView(model: model)
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

struct ConnectionView: View {
    @Bindable var model: AppModel
    @State private var url = ""
    @State private var allowHTTP = false
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Your originals. Your server.", systemImage: "cloud").font(.title2)
                    Text(
                        "Sign in with an administrator-provisioned account. Passkeys are handled by your identity provider in Apple's system browser; no password or passkey is collected by Nephos."
                    )
                }
                if let connection = model.connection {
                    Section("Approved server") {
                        Text(connection.baseURL.absoluteString).textSelection(.enabled)
                        LabeledContent("Server ID", value: connection.config.serverId)
                        Text("Issuer: \(connection.config.issuer)").font(.caption).textSelection(.enabled)
                        Button("Sign in with passkey / known account") {
                            busy = true
                            Task {
                                await model.login()
                                busy = false
                            }
                        }.disabled(busy)
                    }
                }
                Section("Configure server") {
                    TextField("https://photos.example.com", text: $url)
                        .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    #if DEBUG
                        Toggle("Allow local development HTTP", isOn: $allowHTTP)
                        Text(
                            "DEBUG only. Sends credentials/media without encryption on explicitly selected localhost/private IPv4/.local networks. Never use real private media on an untrusted LAN."
                        ).font(.caption)
                    #endif
                    Button("Check server") {
                        busy = true
                        Task {
                            await model.probe(url: url, allowHTTP: allowHTTP)
                            busy = false
                        }
                    }.disabled(busy || url.isEmpty)
                }
                if let proposed = model.proposedConnection {
                    Section("Trust this server and issuer?") {
                        Text(proposed.baseURL.absoluteString)
                        Text("Identity: \(proposed.config.serverId)")
                        Text("Sign-in issuer: \(proposed.config.issuer)")
                        Text(
                            "Confirm these values with your operator. Server discovery does not establish trust. Changing a server signs out and keeps prior account upload staging isolated."
                        ).font(.caption)
                        Button("Approve server") { Task { await model.approveConnection() } }
                        Button("Cancel", role: .cancel) { model.proposedConnection = nil }
                    }
                }
                if busy { ProgressView(model.activity.isEmpty ? "Checking…" : model.activity) }
            }
            .navigationTitle("Nephos")
        }
    }
}

struct GalleryView: View {
    @Bindable var model: AppModel
    @State private var datePicker = false
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        LibrarySelector(model: model)
                        if model.galleryIsStale {
                            Label(
                                "Offline or refresh failed — cached metadata may be stale. Media needs current authorization.",
                                systemImage: "wifi.slash"
                            )
                            .font(.caption).foregroundStyle(.orange)
                        }
                        if let snapshot = model.retainedGallery?.snapshot {
                            Text("\(snapshot.totalCount) items • snapshot revision \(snapshot.revision)").font(.caption)
                        }
                        if model.ledger.selectedLibraryID == nil {
                            ContentUnavailableView(
                                "Choose a library", systemImage: "photo.stack",
                                description: Text("Your server library is available without Photos permission."))
                        } else if model.gallery.items.isEmpty && !model.isLoadingGallery {
                            ContentUnavailableView(
                                "No loaded media", systemImage: "photo",
                                description: Text(
                                    "Pull to refresh. Connection and permission failures are shown separately, not treated as an empty library."
                                ))
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 8)], spacing: 8) {
                            ForEach(model.gallery.items) { asset in
                                NavigationLink {
                                    OriginalView(asset: asset, model: model)
                                } label: {
                                    AssetTile(asset: asset, model: model)
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
                        if model.isLoadingGallery { ProgressView("Loading gallery…").frame(maxWidth: .infinity) }
                        if model.gallery.nextCursor != nil {
                            Button("Load older photos and videos") { Task { await model.loadGallery() } }
                                .buttonStyle(.bordered).frame(maxWidth: .infinity)
                        }
                        Text(
                            "Up to 300 items are cached. Refresh preserves your visible date; Newest returns to recent captures. Date counts and pages belong to a retained snapshot."
                        ).font(.caption).foregroundStyle(.secondary)
                    }.padding()
                }
                .coordinateSpace(name: "gallery")
                .onPreferenceChange(GalleryPositions.self) { positions in
                    if let id = positions.filter({ $0.value >= -40 }).min(by: { $0.value < $1.value })?.key,
                        model.visibleAnchor != id
                    {
                        model.rememberAnchor(id)
                    }
                }
                .onChange(of: model.gallery.items.map(\.id)) { _, _ in
                    if let id = model.scrollTarget ?? model.visibleAnchor { proxy.scrollTo(id, anchor: .top) }
                }
                .refreshable { await model.loadGallery(reset: true) }
                .navigationTitle("Gallery")
                .toolbar {
                    Button("Newest") { Task { await model.loadGallery(reset: true, newest: true) } }
                    Button {
                        datePicker = true
                    } label: {
                        Label("Jump to date", systemImage: "calendar")
                    }
                    .disabled(model.retainedGallery == nil)
                    Button {
                        Task { await model.loadGallery(reset: true) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .sheet(isPresented: $datePicker) { TimelineView(model: model) }
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
                ForEach(model.libraries) { Text($0.name).tag(Optional($0.id)) }
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
        VStack(alignment: .leading, spacing: 4) {
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
            }.frame(height: 115).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
            Text(asset.fileName).font(.caption).lineLimit(1).foregroundStyle(.primary)
            if unavailable { Text("Preview unavailable").font(.caption2).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(asset.isVideo ? "Video" : "Photo"), \(asset.fileName)")
        .task(id: "\(model.account ?? "")/\(asset.id)") {
            guard asset.hasPreview, let api = model.api, let account = model.account else { return }
            do {
                let loaded = try await MediaCache.shared.preview(asset, api: api, account: account)
                guard model.account == account else { return }
                image = loaded
            } catch {
                guard !(error is CancellationError) else { return }
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
    var body: some View {
        VStack {
            if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image).resizable().scaledToFit().frame(
                        minWidth: 300, idealWidth: 800, maxWidth: 1600)
                }
            } else if let player {
                VideoPlayer(player: player)
            } else if let failure {
                ContentUnavailableView(
                    "Cannot display original", systemImage: "exclamationmark.triangle", description: Text(failure))
                Button("Retry") { retry += 1 }
            } else {
                ProgressView("Downloading and verifying original…")
            }
            Text("\(asset.fileName) • \(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file))").font(
                .caption
            ).padding()
            if asset.isVideo {
                Text(
                    "Authenticated, bounded range playback. Export verifies the complete SHA-256; playback alone is not backup evidence."
                ).font(.caption2)
            }
            if let manifest {
                Text("\(manifest.kind) • \(manifest.resources.count) original resource(s)").font(.caption)
                if !manifest.restoreSupported {
                    Text(
                        "Edited/archive resources cannot be reconstructed accurately in Photos. Export all originals and the manifest; phone cleanup stays blocked."
                    ).font(.caption).foregroundStyle(.orange)
                }
                Button("Verify complete server retention") {
                    exporting = true
                    exportTask = Task {
                        defer { exporting = false }
                        do { outcome = try await model.verifyRetention(manifest) } catch {
                            outcome = error.localizedDescription
                            model.handle(error)
                        }
                    }
                }.disabled(exporting)
            }
            if let outcome { Text(outcome).font(.caption) }
            if exporting { ProgressView("Downloading and SHA-256 verifying every original…") }
            HStack {
                Button("Export all originals") { prepareExport(restore: false) }
                Button("Save back to Photos") { prepareExport(restore: true) }
                    .disabled(
                        manifest.map { !$0.restoreSupported } ?? !(asset.isVideo || asset.mediaType.hasPrefix("image/"))
                    )
            }.buttonStyle(.bordered).disabled(exporting || !manifestLoaded)
            Text(
                "Export files are temporary until you save them in Files or Photos. Leaving this viewer cancels downloads and removes its cache."
            ).font(.caption2).foregroundStyle(.secondary).padding()
        }
        .navigationTitle(asset.isVideo ? "Video" : "Photo")
        .navigationBarTitleDisplayMode(.inline)
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
                    let downloaded = try await MediaCache.original(asset, api: api, directory: model.viewerDirectory())
                    guard version == model.epoch else {
                        try? FileManager.default.removeItem(at: downloaded)
                        return
                    }
                    file = downloaded
                    image = try MediaCache.image(downloaded)
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
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LibrarySelector(model: model)
                    if model.needsReauthentication {
                        Button("Session expired — sign in to resume") { Task { await model.login() } }
                    }
                    Text(model.photosStatus)
                    Button("Grant / check Photos access") { Task { await model.requestPhotos() } }
                    Button("Select photos and videos") {
                        Task {
                            await model.requestPhotos()
                            picker = true
                        }
                    }.disabled(model.selectedLibrary == nil || model.isRunning)
                    Button("Resume uploads / scan accessible Photos") {
                        Task { await model.runBackup(ignoreBackoff: true) }
                    }
                    .disabled(model.isRunning || model.selectedLibrary == nil)
                    if model.isRunning { ProgressView(model.activity) }
                    Text(
                        "Uploads use originals, not thumbnails. Selected imports require Photos identity access. Cloud-only originals may download first. Wi-Fi is the default."
                    ).font(.caption)
                }
                Section("Phone-space cleanup") {
                    Text(
                        "Only verified, unchanged, unedited single-resource photos/videos can proceed. Each removal requires a fresh server retention hold and your confirmation."
                    )
                    Button("Review verified phone copies", role: .destructive) { model.checkCleanup() }.disabled(
                        model.isRunning)
                    if !model.cleanupReport.isEmpty { Text(model.cleanupReport).font(.caption) }
                }
                Section("Whole Photos items") {
                    ForEach(
                        Array(
                            (model.ledger.resourceSets ?? []).filter { $0.libraryId == model.ledger.selectedLibraryID }
                                .suffix(100).reversed())
                    ) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.source.resourceNames.first ?? group.kind).font(.headline)
                            Text(
                                group.manifest == nil
                                    ? "Incomplete \(group.kind): required \(group.source.resourceNames.count) resources; cleanup blocked"
                                    : "Complete \(group.kind): \(group.manifest?.resources.count ?? 0) verified originals published"
                            )
                            .font(.caption).foregroundStyle(group.manifest == nil ? .orange : .green)
                            if let error = group.error { Text(error).font(.caption).foregroundStyle(.red) }
                            if let retry = group.nextRetryAt {
                                Text("Retry after \(retry.formatted()) or choose Resume.").font(.caption)
                            }
                        }
                    }
                }
                Section("Recent uploads (\(model.ledger.records.count) tracked)") {
                    if model.recentUploads.isEmpty { Text("No originals have been queued for this account.") }
                    ForEach(model.recentUploads) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.fileName).font(.headline)
                            Text(
                                "\(record.phase.rawValue) resource • \(ByteCountFormatter.string(fromByteCount: record.size, countStyle: .file))"
                            )
                            if let set = model.ledger.resourceSets?.first(where: { $0.id == record.resourceSetId }) {
                                Text(
                                    set.manifest == nil
                                        ? "Whole item incomplete — publication pending"
                                        : "Complete \(set.kind) set published"
                                ).font(.caption).foregroundStyle(set.manifest == nil ? .orange : .green)
                                if let error = set.error { Text(error).font(.caption).foregroundStyle(.red) }
                            }
                            if !record.source.cleanupSupported {
                                Text(
                                    "Cleanup blocked for compound/edited/unsupported sources. Complete originals can be exported from Gallery."
                                ).font(.caption)
                            }
                            if record.remoteRemoved == true {
                                Text("Removed remotely; this revision will not be automatically re-uploaded.").font(
                                    .caption)
                            }
                            if let cleanup = record.cleanupState { Text("Photos removal: \(cleanup)").font(.caption) }
                            if let error = record.error { Text(error).font(.caption).foregroundStyle(.red) }
                        }
                    }
                }
            }
            .navigationTitle("Backup")
            .sheet(isPresented: $picker) {
                NativePhotoPicker { identifiers, missing in
                    picker = false
                    if missing > 0 {
                        model.message =
                            "\(missing) selection(s) did not provide an accessible Photos identifier. They were not imported or marked safe for removal."
                    }
                    Task { await model.importSelected(identifiers) }
                }
            }
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
        NavigationStack {
            Form {
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
