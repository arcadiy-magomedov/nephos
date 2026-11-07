import Photos
import PhotosUI
import SwiftUI
import UIKit

struct OnboardingView: View {
    let model: AppModel
    init(model: AppModel) { self.model = model }
    #if UI_QUALIFICATION
        init(qualificationModel: AppModel, step: Int) {
            model = qualificationModel
            _step = State(initialValue: step >= 5 ? .ready : step == 4 ? .photos : step == 3 ? .library : .login)
            _selectedLibrary = State(initialValue: qualificationModel.ledger.selectedLibraryID)
        }
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var step = Step.login
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var error: String?
    @State private var scanner = false
    @State private var selectedImage: PhotosPickerItem?
    @State private var selectedLibrary: UUID?
    @State private var backup = false
    @State private var wifiOnly = true
    @State private var permission = PHAuthorizationStatus.notDetermined
    @State private var pending = false

    private enum Step: Int, CaseIterable { case login, library, photos, ready }
    private var chosenLibrary: Library? { model.libraries.first { $0.id == selectedLibrary } }
    private var canReadPhotos: Bool { permission == .authorized || permission == .limited }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    ForEach(Step.allCases, id: \.rawValue) { item in
                        Capsule().fill(
                            item.rawValue <= step.rawValue ? NephosStyle.accent : Color.secondary.opacity(0.15)
                        ).frame(height: 3)
                    }
                }.padding(24).accessibilityHidden(true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        content
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.subheadline).accessibilityIdentifier("onboarding.qrError")
                        }
                        if busy { ProgressView("Signing in securely…") }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
                VStack(spacing: 10) { footer }
                    .padding(24).frame(maxWidth: .infinity).background(.bar)
                    .disabled(busy || model.isSigningIn)
                if busy { Button("Cancel") { operation?.cancel() }.padding(.bottom, 12) }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        Label("Appearance", systemImage: "circle.lefthalf.filled")
                    }
                }
            }
            .sheet(isPresented: $scanner) {
                NavigationStack {
                    QRScanner { result in
                        scanner = false
                        switch result {
                        case .success(let raw): consume(raw)
                        case .failure(let failure): error = failure.localizedDescription
                        }
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Scan Nephos QR")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { scanner = false }
                        }
                    }
                }.interactiveDismissDisabled(false)
            }
            .task {
                pending = model.hasPendingEnrollment
                permission = model.photos.authorization
                if !model.signedIn {
                    error = model.message
                    model.message = nil
                }
                if model.needsOnboarding { resumeSetup() }
            }
            .onChange(of: selectedImage) { _, item in
                guard let item else { return }
                perform {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw QREnrollmentError.invalidQR
                    }
                    let raw = try await Task.detached { try QRImageDecoder.payload(data) }.value
                    try Task.checkCancellation()
                    try await model.enroll(qr: EnrollmentQR.parse(raw))
                    resumeSetup()
                    selectedImage = nil
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { permission = model.photos.authorization }
                if phase == .background { scanner = false }
            }
            .onChange(of: model.signedIn) { _, value in
                if value && model.needsOnboarding && !busy { resumeSetup() }
                if !value { step = .login }
            }
            .onDisappear { operation?.cancel() }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .login:
            heading("Sign in with QR", symbol: "qrcode.viewfinder")
            Text("Ask your administrator for a Nephos sign-in QR code. Scan it, or import its image on this iPhone.")
                .foregroundStyle(.secondary)
            Text(
                "The code is valid for 10 minutes and enrolls one device. Only trusted HTTPS connections are accepted."
            )
            .font(.footnote).foregroundStyle(.secondary)
            PhotosPicker(selection: $selectedImage, matching: .images, photoLibrary: .shared()) {
                Label("Import QR from Photos", systemImage: "photo")
            }.buttonStyle(.bordered).disabled(busy).accessibilityIdentifier("onboarding.importQR")
            Text("Importing an image does not grant Nephos access to your photo library or enable backup.")
                .font(.footnote).foregroundStyle(.secondary)
            if pending {
                Text("A securely saved sign-in can be resumed with this device's original key.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .library:
            heading("How will you use Nephos?", symbol: "folder")
            Text("Browse your server library, or also back up originals from this iPhone.")
            if model.libraries.isEmpty {
                Text("No library is available yet. Ask your administrator to grant access.")
                Button("Refresh libraries") { perform { try await model.loadLibraries(reset: true) } }
            } else {
                Picker("Library", selection: $selectedLibrary) {
                    Text("Choose a library").tag(Optional<UUID>.none)
                    ForEach(model.libraries) {
                        Text($0.name + ($0.isReadOnly ? " (shared)" : "")).tag(Optional($0.id))
                    }
                }.pickerStyle(.menu)
                if model.libraryCursor != nil {
                    Button("Load more libraries") { perform { try await model.loadLibraries() } }
                }
                Text(
                    chosenLibrary?.isReadOnly == true
                        ? "This shared library is browse-only." : "Backup is optional. Originals stay in Photos."
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
        case .photos:
            heading("Back up iPhone photos", symbol: "photo.on.rectangle")
            Text("Allow access only to photos and videos you want to back up. Selected Photos access is supported.")
            Toggle("Wi-Fi only", isOn: $wifiOnly)
            Text("This never enables cleanup. iOS controls background execution.")
                .font(.footnote).foregroundStyle(.secondary)
            if permission == .denied || permission == .restricted {
                Text("Photos access is off. You can still browse, or enable access in iPhone Settings.")
            } else if permission == .limited {
                Label("Only selected photos are accessible", systemImage: "photo.badge.checkmark")
            }
        case .ready:
            heading(backup ? "Ready to back up" : "Ready to browse", symbol: "checkmark")
            if let chosenLibrary { Text(chosenLibrary.name).font(.headline) }
            Text(
                backup
                    ? "Backup starts after you open the library. Originals are verified before being marked saved."
                    : "Browse without access to photos on this iPhone."
            )
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var footer: some View {
        switch step {
        case .login:
            primary("Scan QR code") {
                error = nil
                scanner = true
            }
            .accessibilityIdentifier("onboarding.scanQR")
            if pending {
                Button("Resume saved sign-in") {
                    perform {
                        try await model.resumeQREnrollment()
                        resumeSetup()
                    }
                }.accessibilityIdentifier("onboarding.resumeQR")
                Button("Cancel saved sign-in") {
                    do {
                        try model.cancelQREnrollment()
                        pending = false
                        error = "Sign-in cancelled."
                    } catch { self.error = error.localizedDescription }
                }
            }
            if error != nil { Button("Camera settings", action: openSettings) }
        case .library:
            primary("Set up backup") { chooseMode(true) }
                .disabled(chosenLibrary == nil || chosenLibrary?.isReadOnly == true)
            Button("Browse only") { chooseMode(false) }.disabled(chosenLibrary == nil)
            Button("Sign out") {
                perform {
                    try await model.signOut()
                    step = .login
                }
            }
        case .photos:
            if permission == .denied || permission == .restricted {
                primary("Open iPhone Settings", action: openSettings)
            } else {
                primary(canReadPhotos ? "Continue" : "Allow Photos access") {
                    perform {
                        if !canReadPhotos { await model.requestPhotos() }
                        permission = model.photos.authorization
                        if canReadPhotos {
                            try await saveDraft(ready: true)
                            step = .ready
                        }
                    }
                }
            }
            Button("Continue without backup") { chooseMode(false) }
        case .ready:
            primary("Open library") {
                perform {
                    guard let selectedLibrary else { throw ClientError.invalid("Choose a library.") }
                    try await model.completeOnboarding(
                        library: selectedLibrary, backup: backup, allowCellular: !wifiOnly)
                }
            }.disabled(chosenLibrary == nil)
            Button("Change setup") { step = .library }
        }
    }

    private func consume(_ raw: String) {
        perform {
            try await model.enroll(qr: EnrollmentQR.parse(raw))
            resumeSetup()
        }
    }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        operation = Task { @MainActor in
            defer {
                busy = false
                pending = model.hasPendingEnrollment
                operation = nil
            }
            do { try await work() } catch {
                if AuthSession.isCancelled(error) {
                    self.error = "Sign-in cancelled. A saved exchange can still be resumed."
                } else if let network = error as? URLError,
                    [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost]
                        .contains(network.code)
                {
                    self.error = "Offline or unable to reach the server. Retry your saved sign-in when connected."
                } else {
                    self.error = error.localizedDescription
                }
            }
        }
    }
    private func resumeSetup() {
        guard model.signedIn else { return }
        permission = model.photos.authorization
        if let draft = model.ledger.onboarding {
            selectedLibrary = draft.libraryID
            backup = draft.backup
            wifiOnly = !draft.allowCellular
            step = draft.ready && (!backup || canReadPhotos) ? .ready : .photos
        } else {
            selectedLibrary =
                model.ledger.selectedLibraryID ?? (model.libraries.count == 1 ? model.libraries.first?.id : nil)
            step = .library
        }
    }
    private func saveDraft(ready: Bool) async throws {
        guard let selectedLibrary else { throw ClientError.invalid("Choose a library.") }
        try await model.saveOnboarding(
            OnboardingDraft(libraryID: selectedLibrary, backup: backup, allowCellular: !wifiOnly, ready: ready))
    }
    private func chooseMode(_ enabled: Bool) {
        perform {
            backup = enabled
            try await saveDraft(ready: !enabled)
            permission = model.photos.authorization
            step = enabled ? .photos : .ready
        }
    }
    private func heading(_ title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: symbol).font(.system(size: 29)).foregroundStyle(NephosStyle.accent)
            Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
        }
    }
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity).padding(.vertical, 8) }
            .buttonStyle(.borderedProminent).controlSize(.large)
    }
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
