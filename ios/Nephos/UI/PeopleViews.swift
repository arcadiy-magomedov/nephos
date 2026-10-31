import SwiftUI

struct FacePortrait: View {
    let model: AppModel
    var personID: UUID?
    var observation: FaceObservation?
    @State private var image: UIImage?
    @State private var failure: String?

    var body: some View {
        Circle().fill(NephosStyle.accent.opacity(0.1))
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: failure == nil ? "person.fill" : "exclamationmark.triangle")
                        .font(.title2).foregroundStyle(.secondary)
                }
            }
            .clipShape(Circle())
            .accessibilityLabel(failure ?? "Recognized face")
            .task(id: "\(model.mediaGeneration)/\(personID?.uuidString ?? observation?.id.uuidString ?? "")") {
                guard let api = model.api, let account = model.account else { return }
                let epoch = model.epoch
                let generation = model.mediaGeneration
                do {
                    let face: FaceObservation?
                    if let observation {
                        face = observation
                    } else if let personID {
                        face = try await api.observations(person: personID).items.first
                    } else {
                        face = nil
                    }
                    guard let face else { return }
                    let asset = try await api.asset(face.assetId)
                    let preview = try await MediaCache.shared.preview(asset, api: api, account: account, size: .screen)
                    guard let source = preview.cgImage,
                        let rect = face.cropRect(pixelWidth: source.width, pixelHeight: source.height),
                        let crop = source.cropping(to: rect)
                    else { throw ClientError.invalid("The face crop is unavailable.") }
                    guard epoch == model.epoch, generation == model.mediaGeneration, !Task.isCancelled else { return }
                    image = UIImage(cgImage: crop)
                } catch {
                    guard epoch == model.epoch, generation == model.mediaGeneration, !Task.isCancelled,
                        !(error is CancellationError)
                    else { return }
                    image = nil
                    failure = error.localizedDescription
                    if case ClientError.signedOut = error { model.handle(error) }
                }
            }
    }
}

struct PeopleView: View {
    let model: AppModel
    var excluding: UUID?
    var choose: ((FacePerson) -> Void)?
    @State private var page = RemoteList<FacePerson, UUID>()
    @State private var query = ""

    private var people: [FacePerson] {
        page.items.filter { $0.redirectId == nil && $0.id != excluding }
    }
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 22)], spacing: 24) {
                ForEach(people) { person in
                    Group {
                        if let choose {
                            Button {
                                choose(person)
                            } label: {
                                tile(person)
                            }
                        } else {
                            NavigationLink {
                                PersonView(model: model, person: person)
                            } label: {
                                tile(person)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }.padding()
            if page.loaded && people.isEmpty && page.failure == nil {
                ContentUnavailableView(
                    "No people found", systemImage: "person.2",
                    description: Text("Photos are analyzed on your server. Search uses an exact name or alias."))
            }
            RemoteListFooter(page: page) { await load() }
            Text("Names and face corrections are private to your account.")
                .font(.footnote).foregroundStyle(.secondary).padding()
        }
        .navigationTitle(choose == nil ? "People" : "Choose a person")
        .searchable(text: $query, prompt: "Exact name or alias")
        .toolbar {
            if choose == nil {
                NavigationLink {
                    CorrectionsView(model: model)
                } label: {
                    Label("Correction history", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .task(id: query) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await load(reset: true)
        }
        .refreshable { await load(reset: true) }
    }
    private func tile(_ person: FacePerson) -> some View {
        VStack(spacing: 10) {
            FacePortrait(model: model, personID: person.id).frame(width: 104, height: 104)
            Text(person.displayName).font(.headline).foregroundStyle(.primary).lineLimit(2)
        }.frame(maxWidth: .infinity)
    }
    private func load(reset: Bool = false) async {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        await page.load(reset: reset, model: model) { cursor in
            guard let api = model.api else { throw ClientError.signedOut }
            let result = try await api.people(after: cursor, name: name)
            return (result.items, result.next)
        }
    }
}

struct PersonView: View {
    let model: AppModel
    @State var person: FacePerson
    @State private var page = RemoteList<Asset, UUID>()
    @State private var editingName = false
    @State private var merging = false
    @State private var refreshID = UUID()
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                FacePortrait(model: model, personID: person.id).frame(width: 96, height: 96)
                Text(person.displayName).font(.largeTitle.bold())
                if !person.aliases.isEmpty {
                    Text(person.aliases.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                }
                if person.redirectId != nil {
                    Label(
                        "This group has been merged. Refresh People to open the destination.",
                        systemImage: "arrow.triangle.merge"
                    )
                    .font(.callout)
                }
                HStack {
                    Button("Edit name") { editingName = true }
                    Button("Merge…") { merging = true }.disabled(person.redirectId != nil)
                }.buttonStyle(.bordered)
                Text("\(page.items.count) photos loaded").font(.caption).foregroundStyle(.secondary)
            }.padding()
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
                ContentUnavailableView("No accessible photos", systemImage: "photo")
            }
            RemoteListFooter(page: page) { await load() }
        }
        .navigationTitle("Person").navigationBarTitleDisplayMode(.inline)
        .task(id: refreshID) { await load(reset: true) }
        .refreshable { await load(reset: true) }
        .sheet(
            isPresented: $editingName, onDismiss: { refreshID = UUID() },
            content: {
                NavigationStack { PersonNameView(model: model, person: person) }
            }
        )
        .sheet(
            isPresented: $merging, onDismiss: { refreshID = UUID() },
            content: {
                NavigationStack { MergePeopleView(model: model, target: person) }
            })
    }
    private func load(reset: Bool = false) async {
        await page.load(reset: reset, model: model) { cursor in
            guard let api = model.api else { throw ClientError.signedOut }
            let epoch = model.epoch
            let latest = try await api.person(person.id)
            let result = try await api.personAssets(person.id, after: cursor)
            let assets = try await api.assets(ids: result.items)
            guard epoch == model.epoch, !Task.isCancelled else { throw CancellationError() }
            person = latest
            return (assets, result.next)
        }
    }
}

struct PersonNameView: View {
    let model: AppModel
    let person: FacePerson
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var aliases = ""
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        Form {
            Section("Name") { TextField("Unnamed person", text: $name) }
            Section("Aliases, one per line") {
                TextEditor(text: $aliases).frame(minHeight: 100)
            }
            Text("Only you see these names. Clearing the name leaves the face group intact.")
                .font(.footnote).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.red) }
        }
        .navigationTitle("Edit person")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(busy) }
        }
        .interactiveDismissDisabled(busy)
        .onAppear {
            name = person.name ?? ""
            aliases = person.aliases.joined(separator: "\n")
        }
    }
    private func save() async {
        let epoch = model.epoch
        busy = true
        defer { busy = false }
        do {
            guard let api = model.api else { throw ClientError.signedOut }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let input = PersonNameInput(
                name: trimmed.isEmpty ? nil : trimmed,
                aliases: aliases.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            try await api.namePerson(person.id, input: input)
            guard epoch == model.epoch else { return }
            dismiss()
        } catch {
            guard epoch == model.epoch else { return }
            failure = error.localizedDescription
            if case ClientError.signedOut = error { model.handle(error) }
        }
    }
}

struct MergePeopleView: View {
    let model: AppModel
    let target: FacePerson
    @Environment(\.dismiss) private var dismiss
    @State private var source: FacePerson?
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        Group {
            if let source {
                ScrollView {
                    VStack(spacing: 22) {
                        Text("Is this the same person?").font(.title.bold())
                        HStack(spacing: 24) {
                            portrait(target)
                            Image(systemName: "plus")
                            portrait(source)
                        }
                        Text(
                            "The name “\(target.displayName)” will be kept. Originals are unchanged. You can undo the merge in correction history."
                        )
                        .foregroundStyle(.secondary)
                        if let failure { Text(failure).foregroundStyle(.red) }
                        Button("Merge groups") { Task { await apply(merge: true) } }
                            .buttonStyle(.borderedProminent)
                        Button("No, these are different people") { Task { await apply(merge: false) } }
                            .buttonStyle(.bordered)
                        Button("Choose someone else") { self.source = nil }
                        if busy { ProgressView() }
                    }.padding(24).disabled(busy)
                }
            } else {
                PeopleView(model: model, excluding: target.id) { source = $0 }
            }
        }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
        .interactiveDismissDisabled(busy)
    }
    private func portrait(_ person: FacePerson) -> some View {
        VStack {
            FacePortrait(model: model, personID: person.id).frame(width: 86, height: 86)
            Text(person.displayName).font(.headline)
        }
    }
    private func apply(merge: Bool) async {
        guard let source else { return }
        let epoch = model.epoch
        busy = true
        failure = nil
        defer { busy = false }
        do {
            guard let api = model.api else { throw ClientError.signedOut }
            if merge {
                try await api.mergePerson(source.id, into: target.id)
            } else {
                try await api.negativeMatch(target.id, other: source.id)
            }
            guard epoch == model.epoch else { return }
            dismiss()
        } catch {
            guard epoch == model.epoch else { return }
            failure = error.localizedDescription
            if case ClientError.signedOut = error { model.handle(error) }
        }
    }
}

struct CorrectionsView: View {
    let model: AppModel
    @State private var page = RemoteList<FaceCorrection, UUID>()
    var body: some View {
        List {
            ForEach(page.items.sorted { $0.createdAt > $1.createdAt }) { correction in
                CorrectionRow(
                    model: model, correction: correction,
                    negativeWasRemoved: page.items.contains {
                        $0.kind == "negative_removed" && $0.subjectId == correction.subjectId
                            && $0.targetId == correction.targetId && $0.createdAt >= correction.createdAt
                    })
            }
            if page.loaded && page.items.isEmpty { Text("No corrections yet.") }
            RemoteListFooter(page: page) { await load() }
        }
        .navigationTitle("Correction history")
        .task { await load(reset: true) }
        .refreshable { await load(reset: true) }
    }
    private func load(reset: Bool = false) async {
        await page.load(reset: reset, model: model) { cursor in
            guard let api = model.api else { throw ClientError.signedOut }
            let result = try await api.corrections(after: cursor)
            return (result.items, result.next)
        }
    }
}

private struct CorrectionRow: View {
    let model: AppModel
    let correction: FaceCorrection
    let negativeWasRemoved: Bool
    @State private var current: FacePerson?
    @State private var failure: String?
    @State private var confirming = false
    @State private var confirmingNegative = false
    @State private var negativeRemoved = false
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(correction.title).font(.headline)
            if let current { Text(current.displayName).font(.subheadline) }
            Text(GalleryDates.parse(correction.createdAt)?.formatted() ?? correction.createdAt)
                .font(.caption).foregroundStyle(.secondary)
            if correction.kind == "merge", let target = correction.targetId, current?.redirectId == target {
                Button("Undo current merge") { confirming = true }.disabled(busy)
            }
            if correction.kind == "negative", correction.targetId != nil, !negativeRemoved, !negativeWasRemoved {
                Button("Remove different-person rule") { confirmingNegative = true }.disabled(busy)
            }
            if negativeRemoved { Text("Different-person rule removed.").font(.caption) }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
                Button("Retry") { Task { await load() } }
            }
        }
        .task { await load() }
        .confirmationDialog("Restore this separate face group?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Undo merge") { Task { await undo() } }
        }
        .confirmationDialog(
            "Allow these groups to be merged again?", isPresented: $confirmingNegative, titleVisibility: .visible
        ) {
            Button("Remove rule") { Task { await removeNegative() } }
        }
    }
    private func load() async {
        guard !["split", "assign"].contains(correction.kind) else { return }
        let epoch = model.epoch
        do {
            guard let api = model.api else { throw ClientError.signedOut }
            let result = try await api.person(correction.subjectId)
            guard epoch == model.epoch, !Task.isCancelled else { return }
            current = result
            failure = nil
        } catch {
            guard epoch == model.epoch, !Task.isCancelled, !(error is CancellationError) else { return }
            failure = error.localizedDescription
        }
    }
    private func removeNegative() async {
        guard let target = correction.targetId else { return }
        busy = true
        defer { busy = false }
        let epoch = model.epoch
        do {
            guard let api = model.api else { throw ClientError.signedOut }
            try await api.removeNegativeMatch(correction.subjectId, other: target)
            guard epoch == model.epoch else { return }
            negativeRemoved = true
            failure = nil
        } catch {
            guard epoch == model.epoch else { return }
            failure = error.localizedDescription
            if case ClientError.signedOut = error { model.handle(error) }
        }
    }
    private func undo() async {
        busy = true
        defer { busy = false }
        let epoch = model.epoch
        do {
            guard let api = model.api else { throw ClientError.signedOut }
            let latest = try await api.person(correction.subjectId)
            guard latest.redirectId == correction.targetId, latest.redirectId != nil else {
                throw ClientError.invalid("This merge has already changed. Refresh history.")
            }
            try await api.undoMerge(correction.subjectId)
            guard epoch == model.epoch else { return }
            await load()
        } catch {
            guard epoch == model.epoch else { return }
            failure = error.localizedDescription
            if case ClientError.signedOut = error { model.handle(error) }
        }
    }
}

struct PhotoPeopleView: View {
    let model: AppModel
    let asset: Asset
    @State private var page = RemoteList<FaceObservation, UUID>()
    var body: some View {
        List {
            Text("Names and corrections are private to your account.").font(.footnote).foregroundStyle(.secondary)
            ForEach(page.items) { observation in
                ObservationRow(model: model, observation: observation) { await load(reset: true) }
            }
            if page.loaded && page.items.isEmpty && page.failure == nil {
                Text("No recognized faces are available for this photo.")
            }
            RemoteListFooter(page: page) { await load() }
        }
        .navigationTitle("People in this photo")
        .task { await load(reset: true) }
        .refreshable { await load(reset: true) }
    }
    private func load(reset: Bool = false) async {
        await page.load(reset: reset, model: model) { cursor in
            guard let api = model.api else { throw ClientError.signedOut }
            let result = try await api.observations(asset: asset.id, after: cursor)
            return (result.items, result.next)
        }
    }
}

private struct ObservationRow: View {
    let model: AppModel
    let observation: FaceObservation
    let changed: () async -> Void
    @State private var person: FacePerson?
    @State private var picking = false
    @State private var splitting = false
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                FacePortrait(model: model, observation: observation).frame(width: 60, height: 60)
                if let person {
                    NavigationLink(person.displayName) { PersonView(model: model, person: person) }
                } else {
                    Text("Unnamed face")
                }
                Spacer()
                Menu {
                    Button("Move to another person") { picking = true }
                    Button("Separate into a new person") { splitting = true }
                } label: {
                    Label("Correct face", systemImage: "ellipsis.circle")
                }.disabled(busy)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
        .task(id: observation.personId) {
            let epoch = model.epoch
            do {
                if let id = observation.personId, let api = model.api {
                    let result = try await api.person(id)
                    guard epoch == model.epoch, !Task.isCancelled else { return }
                    person = result
                }
            } catch {
                guard epoch == model.epoch, !Task.isCancelled, !(error is CancellationError) else { return }
                failure = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Separate this face into a new unnamed person?", isPresented: $splitting, titleVisibility: .visible
        ) {
            Button("Separate face") { Task { await assign(nil) } }
        }
        .sheet(isPresented: $picking) {
            NavigationStack {
                PeopleView(model: model) { person in
                    picking = false
                    Task { await assign(person.id) }
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { picking = false } } }
            }
        }
    }
    private func assign(_ target: UUID?) async {
        let epoch = model.epoch
        busy = true
        failure = nil
        defer { busy = false }
        do {
            guard let api = model.api else { throw ClientError.signedOut }
            if let target {
                try await api.assignObservation(observation.id, person: target)
            } else {
                try await api.splitObservation(observation.id)
            }
            guard epoch == model.epoch else { return }
            await changed()
        } catch {
            guard epoch == model.epoch else { return }
            failure = error.localizedDescription
            if case ClientError.signedOut = error { model.handle(error) }
        }
    }
}
