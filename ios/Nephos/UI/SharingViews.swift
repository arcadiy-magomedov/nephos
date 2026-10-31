import SwiftUI

struct ShareSelection: Identifiable {
    let id = UUID()
    let library: Library
    let assets: [UUID]
    var existing: MediaShare?
}

struct ShareComposer: View {
    let model: AppModel
    let selection: ShareSelection
    @Environment(\.dismiss) private var dismiss
    @State private var users = RemoteList<DirectoryUser, String>()
    @State private var recipient: String?
    @State private var allAssets = false
    @State private var query = ""
    @State private var busy = false
    @State private var confirming = false
    @State private var failure: String?
    @State private var shareID = UUID()
    @State private var selectedAssets: Set<UUID> = []
    @State private var pickingAssets = false
    @State private var initialized = false
    @State private var previewAssets: [Asset] = []
    @State private var previewFailure: String?
    var body: some View {
        Form {
            Section("What to share") {
                Text(selection.library.name)
                if !allAssets && !previewAssets.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(previewAssets) { AssetTile(asset: $0, model: model).frame(width: 80, height: 80) }
                        Spacer(minLength: 0)
                    }
                }
                if let previewFailure { Text(previewFailure).font(.caption).foregroundStyle(.red) }
                Button {
                    allAssets = false
                } label: {
                    HStack {
                        Text("Selected items: \(selectedAssets.count)")
                        Spacer()
                        Image(systemName: allAssets ? "circle" : "checkmark.circle.fill")
                    }
                }.accessibilityValue(allAssets ? "Not selected" : "Selected")
                Button {
                    allAssets = true
                } label: {
                    HStack {
                        Text("All my media, including future uploads")
                        Spacer()
                        Image(systemName: allAssets ? "checkmark.circle.fill" : "circle")
                    }
                }.accessibilityValue(allAssets ? "Selected" : "Not selected")
                if allAssets {
                    Text("This also grants access to your future uploads in this library.")
                        .foregroundStyle(.orange)
                } else {
                    Button("Choose photos and videos") { pickingAssets = true }
                    Text("New uploads are not added. Shared media cannot be re-shared.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Known users") {
                if let existing = selection.existing {
                    Label(existing.recipientName, systemImage: "person.crop.circle")
                } else {
                    TextField("Filter loaded users", text: $query)
                    ForEach(
                        users.items.filter {
                            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                        }
                    ) { user in
                        Button {
                            recipient = user.id
                        } label: {
                            HStack {
                                Label(user.name, systemImage: "person.crop.circle")
                                Spacer()
                                if recipient == user.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    if users.loaded && users.items.isEmpty { Text("No other known users are available.") }
                    RemoteListFooter(page: users) { await loadUsers() }
                }
            }
            Section {
                Text(
                    "The recipient can view and download these originals. Your face labels stay private. Revocation cannot remove copies already downloaded."
                )
                .font(.footnote).foregroundStyle(.secondary)
                if let failure { Text(failure).foregroundStyle(.red) }
                Button(selection.existing == nil ? "Share media" : "Save access") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(recipient == nil || (!allAssets && selectedAssets.isEmpty) || busy)
                if busy { ProgressView("Saving access…") }
            }
        }
        .disabled(busy)
        .navigationTitle(selection.existing == nil ? "Share" : "Edit access")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
        .interactiveDismissDisabled(busy)
        .task {
            guard !initialized else { return }
            initialized = true
            recipient = selection.existing?.recipientId
            allAssets = selection.existing?.allAssets ?? false
            selectedAssets = Set(selection.assets)
            if selection.existing == nil { await loadUsers(reset: true) }
        }
        .sheet(isPresented: $pickingAssets) {
            NavigationStack {
                ShareAssetPicker(model: model, library: selection.library, selected: $selectedAssets)
            }
        }
        .task(id: selectedAssets) {
            previewAssets = []
            previewFailure = nil
            guard !selectedAssets.isEmpty else { return }
            let epoch = model.epoch
            do {
                guard let api = model.api else { throw ClientError.signedOut }
                let ids = Array(selectedAssets.sorted { $0.uuidString < $1.uuidString }.prefix(3))
                let result = try await api.assets(ids: ids)
                guard epoch == model.epoch, !Task.isCancelled else { return }
                previewAssets = result
            } catch {
                guard epoch == model.epoch, !Task.isCancelled, !(error is CancellationError) else { return }
                previewFailure = error.localizedDescription
                if case ClientError.signedOut = error { model.handle(error) }
            }
        }
        .confirmationDialog(
            allAssets
                ? "Share all your media in this library, including future uploads?"
                : "Share only the selected originals?",
            isPresented: $confirming, titleVisibility: .visible
        ) {
            Button("Confirm access") { Task { await save() } }
        }
    }
    private func loadUsers(reset: Bool = false) async {
        await users.load(reset: reset, model: model) { cursor in
            guard let api = model.api else { throw ClientError.signedOut }
            let result = try await api.directory(after: cursor)
            return (result.items.filter { $0.id != model.subject }, result.nextCursor)
        }
    }
    private func save() async {
        guard let recipient else { return }
        let epoch = model.epoch
        busy = true
        failure = nil
        defer { busy = false }
        do {
            guard let api = model.api else { throw ClientError.signedOut }
            _ = try await api.putShare(
                selection.existing?.id ?? shareID,
                input: ShareInput(
                    libraryId: selection.library.id, recipientId: recipient,
                    allAssets: allAssets,
                    assetIds: allAssets ? [] : selectedAssets.sorted { $0.uuidString < $1.uuidString }))
            guard epoch == model.epoch else { return }
            dismiss()
        } catch {
            guard epoch == model.epoch else { return }
            failure = error.localizedDescription
            if case ClientError.signedOut = error { model.handle(error) }
        }
    }
}

private struct ShareAssetPicker: View {
    let model: AppModel
    let library: Library
    @Binding var selected: Set<UUID>
    @Environment(\.dismiss) private var dismiss
    @State private var page = RemoteList<Asset, GalleryCursor>()
    var body: some View {
        ScrollView {
            Text("\(selected.count) of 500 selected").font(.caption).padding()
            LazyVGrid(columns: NephosStyle.columns, spacing: 3) {
                ForEach(page.items.filter { $0.sharedBy == nil }) { asset in
                    Button {
                        if selected.contains(asset.id) { selected.remove(asset.id) } else { selected.insert(asset.id) }
                    } label: {
                        AssetTile(asset: asset, model: model)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: selected.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(.white).shadow(radius: 2).padding(6)
                            }
                    }.disabled(selected.count >= 500 && !selected.contains(asset.id))
                }
            }.padding(.horizontal)
            RemoteListFooter(page: page) { await load() }
        }
        .navigationTitle("Select media")
        .toolbar { Button("Done") { dismiss() } }
        .task { await load(reset: true) }
    }
    private func load(reset: Bool = false) async {
        await page.load(reset: reset, model: model) { cursor in
            guard let api = model.api else { throw ClientError.signedOut }
            let result = try await api.assets(library: library.id, cursor: cursor)
            return (result.items, result.nextCursor)
        }
    }
}

struct CollectionsView: View {
    let model: AppModel
    @State private var shared = false
    var body: some View {
        VStack(spacing: 0) {
            Picker("Collections", selection: $shared) {
                Text("Mine").tag(false)
                Text("Shared with me").tag(true)
            }.pickerStyle(.segmented).padding()
            if shared {
                SharingListView(model: model, received: true)
            } else {
                List {
                    Section {
                        ContentUnavailableView(
                            "Albums are not available yet", systemImage: "rectangle.stack",
                            description: Text(
                                "Server-side album creation and editing are not implemented. Your libraries and sharing are available below."
                            ))
                    }
                    Section("Libraries") { LibrarySelector(model: model) }
                    Section {
                        NavigationLink {
                            SharingListView(model: model, received: false)
                        } label: {
                            Label("Manage shared access", systemImage: "person.2.badge.gearshape")
                        }
                    }
                }
            }
        }.navigationTitle("Albums")
    }
}

struct SharingListView: View {
    let model: AppModel
    let received: Bool
    @State private var page = RemoteList<MediaShare, UUID>()
    @State private var editing: ShareSelection?
    @State private var revoking: MediaShare?
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        List {
            if !received, let library = model.selectedLibrary, !library.isReadOnly {
                Button {
                    editing = ShareSelection(library: library, assets: [])
                } label: {
                    Label("Share library…", systemImage: "plus")
                }
            }
            ForEach(page.items.filter { received ? $0.recipientId == model.subject : $0.ownerId == model.subject }) {
                share in
                VStack(alignment: .leading, spacing: 10) {
                    Text(received ? share.ownerName : share.recipientName).font(.headline)
                    Text(share.libraryName).foregroundStyle(.secondary)
                    Text(
                        share.allAssets
                            ? "All media, including future uploads" : "\(share.assetIds.count) selected items"
                    )
                    .font(.subheadline)
                    if received {
                        NavigationLink("View shared media") { SharedMediaView(model: model, share: share) }
                        Text("Shared by \(share.ownerName) · read-only").font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Button("Edit access") {
                                editing = ShareSelection(
                                    library: Library(id: share.libraryId, name: share.libraryName),
                                    assets: share.assetIds, existing: share)
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) { revoking = share }
                        }.buttonStyle(.borderless).disabled(busy)
                    }
                }.padding(.vertical, 6)
            }
            if page.loaded
                && page.items.filter({ received ? $0.recipientId == model.subject : $0.ownerId == model.subject })
                    .isEmpty
            {
                Text(received ? "No media has been shared with you." : "You have not shared any media.")
                    .foregroundStyle(.secondary)
            }
            if let failure { Text(failure).foregroundStyle(.red) }
            RemoteListFooter(page: page) { await load() }
        }
        .navigationTitle(received ? "Shared with me" : "Shared access")
        .task { await load(reset: true) }
        .refreshable { await load(reset: true) }
        .sheet(
            item: $editing, onDismiss: { Task { await load(reset: true) } },
            content: { selection in
                NavigationStack { ShareComposer(model: model, selection: selection) }
            }
        )
        .confirmationDialog(
            "Revoke access? Downloaded copies will remain with the recipient.",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            titleVisibility: .visible, presenting: revoking
        ) { share in
            Button("Revoke access", role: .destructive) { Task { await revoke(share) } }
        }
    }
    private func load(reset: Bool = false) async {
        await page.load(reset: reset, model: model) { cursor in
            guard let api = model.api else { throw ClientError.signedOut }
            let result = try await api.shares(after: cursor)
            return (result.items, result.nextCursor)
        }
    }
    private func revoke(_ share: MediaShare) async {
        let epoch = model.epoch
        busy = true
        failure = nil
        defer { busy = false }
        do {
            guard let api = model.api else { throw ClientError.signedOut }
            try await api.deleteShare(share.id)
            guard epoch == model.epoch else { return }
            await load(reset: true)
        } catch {
            guard epoch == model.epoch else { return }
            failure = error.localizedDescription
            if case ClientError.signedOut = error { model.handle(error) }
        }
    }
}

private struct SharedCursor: Hashable {
    let offset: Int
    let gallery: GalleryCursor?
}

struct SharedMediaView: View {
    let model: AppModel
    let share: MediaShare
    @State private var page = RemoteList<Asset, SharedCursor>()
    var body: some View {
        ScrollView {
            Text(
                share.allAssets
                    ? "Accessible media in \(share.libraryName). Shared items show their owner."
                    : "Shared by \(share.ownerName) · read-only"
            )
            .font(.footnote).foregroundStyle(.secondary).padding()
            LazyVGrid(columns: NephosStyle.columns, spacing: 3) {
                ForEach(page.items) { asset in
                    NavigationLink {
                        OriginalView(asset: asset, model: model)
                    } label: {
                        AssetTile(asset: asset, model: model)
                    }
                }
            }.padding(.horizontal)
            if page.loaded && page.items.isEmpty && page.failure == nil {
                ContentUnavailableView("No accessible media", systemImage: "photo")
            }
            RemoteListFooter(page: page) { await load() }
        }
        .navigationTitle(share.libraryName)
        .task { await load(reset: true) }
        .refreshable { await load(reset: true) }
    }
    private func load(reset: Bool = false) async {
        await page.load(reset: reset, model: model) { cursor in
            guard let api = model.api else { throw ClientError.signedOut }
            if share.allAssets {
                let result = try await api.assets(library: share.libraryId, cursor: cursor?.gallery)
                let next = result.nextCursor.map { SharedCursor(offset: 0, gallery: $0) }
                return (result.items, next)
            }
            let offset = cursor?.offset ?? 0
            let ids = Array(share.assetIds.dropFirst(offset).prefix(50))
            let assets = try await api.assets(ids: ids)
            let next = offset + ids.count
            return (assets, next < share.assetIds.count ? SharedCursor(offset: next, gallery: nil) : nil)
        }
    }
}

struct SearchView: View {
    let model: AppModel
    @State private var searchPeople = true
    @State private var query = ""
    var body: some View {
        VStack(spacing: 0) {
            Picker("Search in", selection: $searchPeople) {
                Text("People").tag(true)
                Text("Loaded files").tag(false)
            }.pickerStyle(.segmented).padding()
            if searchPeople {
                PeopleView(model: model).navigationTitle("Search")
            } else {
                ScrollView {
                    Text(
                        "Filename search in the current library's loaded window (up to 300 items), not the entire server."
                    )
                    .font(.footnote).foregroundStyle(.secondary).padding()
                    LazyVGrid(columns: NephosStyle.columns, spacing: 3) {
                        ForEach(
                            model.gallery.items.filter {
                                !query.isEmpty && $0.fileName.localizedCaseInsensitiveContains(query)
                            }
                        ) { asset in
                            NavigationLink {
                                OriginalView(asset: asset, model: model)
                            } label: {
                                AssetTile(asset: asset, model: model)
                            }
                        }
                    }.padding(.horizontal)
                    if query.isEmpty {
                        ContentUnavailableView("Search filenames", systemImage: "magnifyingglass")
                    } else if !model.gallery.items.contains(where: {
                        $0.fileName.localizedCaseInsensitiveContains(query)
                    }) {
                        ContentUnavailableView("No loaded files match", systemImage: "magnifyingglass")
                    }
                }.searchable(text: $query, prompt: "Filename")
            }
            Text("Search by description and combined person + scene queries are not available yet.")
                .font(.footnote).foregroundStyle(.secondary).padding()
        }.navigationTitle("Search")
    }
}
