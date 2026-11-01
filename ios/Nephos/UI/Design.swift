import SwiftUI

extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct AppAppearanceModifier: ViewModifier {
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    func body(content: Content) -> some View {
        content.tint(NephosStyle.accent).preferredColorScheme(appearance.colorScheme)
    }
}

enum NephosStyle {
    static let accent = Color(
        uiColor: UIColor { traits in
            if traits.accessibilityContrast == .high {
                return traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.72, green: 0.96, blue: 0.86, alpha: 1)
                    : UIColor(red: 0.02, green: 0.30, blue: 0.24, alpha: 1)
            }
            return traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.61, green: 0.87, blue: 0.78, alpha: 1)
                : UIColor(red: 0.08, green: 0.46, blue: 0.39, alpha: 1)
        })
    static let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
    static func galleryColumns(accessibility: Bool) -> [GridItem] {
        accessibility ? Array(repeating: GridItem(.flexible(), spacing: 3), count: 2) : columns
    }
}

struct AppearancePicker: View {
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    var body: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.inline)
            Text("System follows the device appearance automatically. A manual choice applies only to Nephos.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct AppearanceSettingsView: View {
    var body: some View {
        Form { AppearancePicker() }.navigationTitle("Appearance")
    }
}

struct BackupStatusView: View {
    let model: AppModel
    private var progress: BackupProgress {
        BackupProgress(ledger: model.ledger, library: model.ledger.selectedLibraryID)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(
                model.ledger.settings.backupPaused == true
                    ? "Backup paused"
                    : model.needsReauthentication
                        ? "Sign in to continue"
                        : model.isRunning
                            ? "Backing up"
                            : progress.failed > 0
                                ? "Some backups stopped"
                                : progress.total == 0
                                    ? "Ready to back up"
                                    : progress.isComplete ? "Backup complete" : "Backup queued"
            )
            .font(.headline)
            Text("\(model.backupItemCounts.saved) saved · \(model.backupItemCounts.remaining) remaining")
                .font(.subheadline).foregroundStyle(.secondary)
                .accessibilityLabel("\(progress.verified) of \(progress.total) files saved")
                .accessibilityIdentifier("backup.progress")
            Text(model.ledger.settings.allowCellular ? "Wi-Fi and cellular" : "Wi-Fi only")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InlineFailure: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.secondary)
            Button("Retry", action: retry).buttonStyle(.bordered)
        }.padding().frame(maxWidth: .infinity)
    }
}

@MainActor @Observable
final class RemoteList<Item: Identifiable, Cursor: Hashable> {
    var items: [Item] = []
    var next: Cursor?
    var loaded = false
    var loading = false
    var failure: String?
    private var requestID = UUID()
    private var cursors: Set<Cursor> = []

    func load(
        reset: Bool = false, model: AppModel,
        onLoaded: (() -> Void)? = nil,
        fetch: (Cursor?) async throws -> ([Item], Cursor?)
    ) async {
        if !reset && (loading || (loaded && next == nil)) { return }
        let request = UUID()
        requestID = request
        let epoch = model.epoch
        let generation = model.mediaGeneration
        if reset {
            items = []
            next = nil
            loaded = false
            cursors = []
        }
        loading = true
        failure = nil
        defer { if requestID == request { loading = false } }
        do {
            guard model.api != nil else { throw ClientError.signedOut }
            let (rows, cursor) = try await fetch(next)
            try Task.checkCancellation()
            guard requestID == request, epoch == model.epoch, generation == model.mediaGeneration else { return }
            if let cursor, !cursors.insert(cursor).inserted {
                throw ClientError.invalid("The server repeated a page cursor. Refresh to start again.")
            }
            var known = Set(items.map(\.id))
            items += rows.filter { known.insert($0.id).inserted }
            if items.count > 300 { items.removeFirst(items.count - 300) }
            next = cursor
            loaded = true
            onLoaded?()
        } catch {
            guard requestID == request, epoch == model.epoch, generation == model.mediaGeneration, !Task.isCancelled,
                !(error is CancellationError)
            else { return }
            failure = error.localizedDescription
            if AppModel.accessDenied(error) { items = [] }
            if case ClientError.signedOut = error { model.handle(error) }
        }
    }
}

struct RemoteListFooter<Item: Identifiable, Cursor: Hashable>: View {
    let page: RemoteList<Item, Cursor>
    let load: () async -> Void
    var body: some View {
        if page.loading {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if let failure = page.failure {
            InlineFailure(message: failure) { Task { await load() } }
        } else if page.next != nil {
            Button("Load more") { Task { await load() } }
                .buttonStyle(.bordered).frame(maxWidth: .infinity).padding()
        }
    }
}
