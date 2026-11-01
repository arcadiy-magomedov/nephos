import Photos
import SwiftUI
import UIKit

struct OnboardingView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("onboardingCheckedURL") private var checkedURL = ""
    @State private var step = Step.server
    @State private var url = ""
    @State private var allowHTTP = false
    @State private var busy = false
    @State private var operationTask: Task<Void, Never>?
    @State private var failure: OnboardingFailure?
    @State private var notice: String?
    @State private var selectedLibrary: UUID?
    @State private var backup = false
    @State private var wifiOnly = true
    @State private var email = ""
    @State private var pin = ""
    @State private var requestedEmail: String?
    @State private var pinExpiry: Date?
    @State private var permission = PHAuthorizationStatus.notDetermined
    @State private var initialized = false
    @State private var discovery = ServerDiscovery()

    private enum Step: Int, CaseIterable {
        case server, trust, signIn, enterPin, library, photos, ready
    }

    private var chosenLibrary: Library? { model.libraries.first { $0.id == selectedLibrary } }
    private var canReadPhotos: Bool { permission == .authorized || permission == .limited }
    private var candidate: Connection? { model.proposedConnection }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: back) { Image(systemName: "chevron.left") }
                        .buttonStyle(.bordered).clipShape(Circle()).accessibilityLabel("Back")
                        .disabled(step == .server || step == .library || busy)
                    HStack(spacing: 5) {
                        ForEach(Step.allCases, id: \.rawValue) { item in
                            Capsule().fill(
                                item.rawValue <= step.rawValue ? NephosStyle.accent : Color.secondary.opacity(0.15)
                            )
                            .frame(height: 3)
                        }
                    }.accessibilityHidden(true)
                    Text("\(step.rawValue + 1) of \(Step.allCases.count)").font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal, 22).padding(.vertical, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let failure { failureContent(failure) } else { content }
                        if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
                .scrollDismissesKeyboard(.interactively)
                VStack(spacing: 8) {
                    if busy { ProgressView("Please wait…").font(.footnote) }
                    footer
                }
                .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 12)
                .frame(maxWidth: .infinity).background(.bar)
                .disabled(busy || model.isSigningIn)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        Label("Appearance", systemImage: "circle.lefthalf.filled")
                    }.disabled(busy)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .task {
                guard !initialized else { return }
                initialized = true
                url = checkedURL.isEmpty ? (model.connection?.baseURL.absoluteString ?? "") : checkedURL
                allowHTTP = model.connection?.allowDevelopmentHTTP ?? false
                permission = model.photos.authorization
                if model.needsOnboarding {
                    resumeSetup()
                } else if let connection = model.connection {
                    if OnboardingPolicy.requiresServerReview(connection, draftURL: url) {
                        notice =
                            "Check the server again to confirm its current sign-in address. The saved connection has not been reused."
                    } else {
                        step = .signIn
                    }
                }
            }
            .onChange(of: model.signedIn) { _, signedIn in
                guard !model.isSigningIn else { return }
                if signedIn && model.needsOnboarding {
                    resumeSetup()
                } else if !signedIn && step.rawValue >= Step.library.rawValue {
                    step = .signIn
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { permission = model.photos.authorization }
                if phase == .background { discovery.stop() }
            }
            .onChange(of: step) { _, step in
                if step != .server { discovery.stop() }
            }
            .onChange(of: model.connection) { _, _ in
                requestedEmail = nil
                pinExpiry = nil
                pin = ""
                if step == .enterPin { step = .signIn }
            }
            .onDisappear {
                discovery.stop()
                operationTask?.cancel()
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .server:
            heading("Connect your server", symbol: "externaldrive.connected.to.line.below")
            description("Find your Nephos server on this network, or enter the address provided by your administrator.")
            VStack(alignment: .leading, spacing: 10) {
                Text("Server address").font(.subheadline.bold())
                TextField("https://photos.example.net", text: $url)
                    .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().padding(16).background(
                        .quaternary, in: RoundedRectangle(cornerRadius: 13)
                    )
                    .accessibilityIdentifier("onboarding.serverURL")
                    .disabled(busy).submitLabel(.go).onSubmit { checkServer() }
            }
            nearbyServers
            card(
                "Connection first",
                text:
                    "We check the server and sign-in address before opening the browser. You decide whether to trust them."
            )
            #if DEBUG
                DisclosureGroup("Local development") {
                    Toggle("Allow local HTTP API", isOn: $allowHTTP)
                    description(
                        "Unencrypted development access only. Passkeys still need a trusted HTTPS sign-in address. Never use private media on an untrusted network."
                    )
                }.font(.footnote).disabled(busy)
            #endif
        case .trust:
            heading("Is this your server?", symbol: "checkmark.shield")
            description("Continue only if you recognize these addresses or received them from your administrator.")
            if let candidate {
                card("Server", text: candidate.baseURL.absoluteString)
                card("Sign-in address", text: candidate.config.issuer)
                Label(
                    candidate.baseURL.scheme == "https" ? "Secure API connection" : "Unencrypted development API",
                    systemImage: candidate.baseURL.scheme == "https" ? "checkmark" : "exclamationmark.triangle")
                Label("Sign-in discovery is available", systemImage: "checkmark")
                DisclosureGroup("Technical details") {
                    Text("Server ID: \(candidate.config.serverId)").textSelection(.enabled)
                    Text(
                        "A reachable server is not automatically trusted. Confirm its identity with your administrator."
                    )
                }.font(.footnote)
            }
        case .signIn:
            heading("Sign in to Nephos", symbol: "key")
            description("Enter your email. A PIN is generated only for an enabled account added by your administrator.")
            TextField("Email address", text: $email)
                .textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                .autocorrectionDisabled().textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("onboarding.email")
                .disabled(busy)
                .onSubmit { requestPin() }
            card("No account yet?", text: "Ask your administrator to add your email. Self-registration is disabled.")
        case .enterPin:
            heading("Enter your PIN", symbol: "key")
            description("Your administrator can now see the PIN in the admin console. Ask them to give it to you.")
            if let requestedEmail { Text(requestedEmail).font(.subheadline).textSelection(.enabled) }
            TextField("8-digit PIN", text: $pin)
                .textContentType(.oneTimeCode).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("onboarding.pin")
                .disabled(busy)
                .onChange(of: pin) { _, value in
                    pin = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(8))
                }
            if let connection = model.connection { card("Sign-in address", text: connection.config.issuer) }
            if let pinExpiry {
                Text("PIN expires at \(pinExpiry.formatted(date: .omitted, time: .shortened)). It works once.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .library:
            heading("How will you use Nephos?", symbol: "folder")
            description("Browse your server library, or also back up originals from this iPhone.")
            if model.libraries.isEmpty {
                card(
                    "No library is available yet",
                    text:
                        "Ask your administrator to grant access to a library. You can refresh without signing in again."
                )
                Button("Refresh libraries") { loadLibraries(reset: true) }.disabled(busy || model.isSigningIn)
            } else {
                Picker("Library", selection: $selectedLibrary) {
                    Text("Choose a library").tag(Optional<UUID>.none)
                    ForEach(model.libraries) {
                        Text($0.name + ($0.isReadOnly ? " (shared)" : "")).tag(Optional($0.id))
                    }
                }.pickerStyle(.menu).disabled(busy)
                if model.libraryCursor != nil { Button("Load more libraries") { loadLibraries() }.disabled(busy) }
                if chosenLibrary?.isReadOnly == true {
                    card(
                        "Browse-only library",
                        text: "This library is shared with you. Your photos cannot be uploaded into it.")
                } else {
                    card(
                        "Backup is optional",
                        text: "Your originals remain in Photos. Setup never enables deletion from your phone or iCloud."
                    )
                }
            }
        case .photos:
            heading(
                permission == .denied || permission == .restricted ? "Photos access is off" : "Back up iPhone photos",
                symbol: "photo.on.rectangle")
            description(
                "Allow access to the photos and videos you want to back up. Selected Photos access is supported.")
            Toggle("Wi-Fi only", isOn: $wifiOnly).disabled(busy)
            card(
                "Your originals stay in Photos",
                text:
                    "This does not enable cleanup. iOS controls background execution; uploads cannot run continuously when the app is closed."
            )
            if permission == .limited {
                Label("Only selected photos are accessible", systemImage: "photo.badge.checkmark").font(.footnote)
            } else if permission == .denied || permission == .restricted {
                description(
                    "You can still browse the server. Enable Photos access in iPhone Settings to back up originals.")
            }
        case .ready:
            heading(backup ? "Ready to back up" : "Ready to browse", symbol: "checkmark")
            description(
                backup
                    ? "Backup starts after you open the library. Progress and pause are available in Backup settings."
                    : "Your server library is available without access to photos on this iPhone.")
            if let library = chosenLibrary {
                card(
                    library.name,
                    text: backup
                        ? (wifiOnly ? "Backup over Wi-Fi only" : "Backup may use cellular data")
                        : "Browse-only mode")
            }
            if backup {
                description(
                    permission == .limited
                        ? "Only the photos you allowed can be backed up."
                        : "Accessible originals will be added to the upload queue. They are not considered backed up until verified by the server."
                )
            }
        }
    }

    private var nearbyServers: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(discovery.isSearching ? "Stop searching" : "Find nearby servers") {
                if discovery.isSearching { discovery.stop() } else { discovery.start() }
            }.buttonStyle(.bordered).disabled(busy).accessibilityIdentifier("onboarding.findServers")
            if let message = discovery.message {
                description(message)
            } else if discovery.isSearching && discovery.servers.isEmpty {
                ProgressView("Searching local network…").font(.footnote)
                description(
                    "If nothing appears, check Wi-Fi or enter the address manually. Guest networks and VPNs may block discovery."
                )
            }
            ForEach(discovery.servers) { server in
                Button {
                    url = server.url.absoluteString
                    allowHTTP = false
                    checkServer()
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(server.name, systemImage: "server.rack").font(.subheadline.bold())
                        Text(server.url.absoluteString).font(.footnote).multilineTextAlignment(.leading)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .buttonStyle(.bordered).disabled(busy)
                .accessibilityIdentifier("onboarding.discovered." + server.id)
            }
            if !discovery.servers.isEmpty {
                description(
                    "These announcements are not verified. Selecting a server checks its connection; you still decide whether to trust it."
                )
            }
            if discovery.hasOmittedResults {
                description(
                    "Some announcements could not be shown. Only supported HTTPS addresses are listed, up to 32 servers."
                )
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if failure != nil {
            primary("Try again") {
                failure = nil
                if step == .server || step == .trust {
                    checkServer()
                } else if step == .signIn {
                    requestPin()
                } else if step == .enterPin {
                    signIn()
                } else if step == .library {
                    loadLibraries(reset: true)
                } else if step == .ready {
                    finish()
                }
            }
            if step.rawValue < Step.library.rawValue {
                if step == .signIn {
                    secondary("Edit email") { failure = nil }
                } else if step == .enterPin {
                    secondary("Different email") {
                        failure = nil
                        resetPinRequest()
                    }
                }
                secondary("Change server", action: editServer)
            } else {
                secondary("Back to library choice") {
                    step = .library
                    failure = nil
                }
            }
        } else {
            switch step {
            case .server:
                primary("Check server", action: checkServer).disabled(
                    url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .trust:
                primary("Trust and continue") {
                    perform {
                        let approved = model.proposedConnection
                        await model.approveConnection()
                        guard let approved, model.connection == approved, model.proposedConnection == nil else {
                            throw ClientError.invalid(model.message ?? "Server approval could not be saved.")
                        }
                        step = .signIn
                    }
                }.disabled(candidate == nil)
                secondary("Different server", action: editServer)
            case .signIn:
                primary("Continue", action: requestPin).disabled((try? LoginPinPolicy.email(email)) == nil)
                    .accessibilityIdentifier("onboarding.requestPin")
                secondary("Change server", action: editServer)
            case .enterPin:
                primary("Sign in", action: signIn).disabled(pin.count != 8)
                    .accessibilityIdentifier("onboarding.submitPin")
                secondary("Request PIN again", action: requestPin)
                secondary("Different email") { resetPinRequest() }
            case .library:
                primary("Set up backup") { chooseMode(true) }.disabled(
                    chosenLibrary == nil || chosenLibrary?.isReadOnly == true)
                secondary("Browse only") { chooseMode(false) }.disabled(chosenLibrary == nil)
                secondary("Sign out") {
                    perform {
                        try await model.signOut()
                        step = .signIn
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
                secondary("Continue without backup") { chooseMode(false) }
            case .ready:
                primary("Open library", action: finish).disabled(chosenLibrary == nil)
                secondary("Change setup") { step = .library }
            }
        }
    }

    private func heading(_ title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: symbol).font(.system(size: 29))
                .frame(width: 68, height: 68).foregroundStyle(NephosStyle.accent)
                .background(NephosStyle.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 21))
            Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
        }.padding(.top, 8)
    }
    private func description(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func card(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.subheadline.bold())
            Text(text).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(17)
            .background(NephosStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 17))
    }
    private func failureContent(_ failure: OnboardingFailure) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(failure.title, symbol: "exclamationmark.triangle")
            description(failure.guidance)
            card("Server", text: url)
            if let address = failure.address { card("Sign-in address", text: address) }
            DisclosureGroup("Technical details") { Text(failure.detail).font(.footnote).textSelection(.enabled) }
        }
    }
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity).padding(.vertical, 8) }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
    }
    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).font(.subheadline).padding(.vertical, 4)
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        failure = nil
        notice = nil
        operationTask = Task { @MainActor in
            defer {
                busy = false
                operationTask = nil
            }
            do { try await operation() } catch {
                guard !AuthSession.isCancelled(error) else { return }
                failure = OnboardingFailure(error, identity: step == .signIn || step == .enterPin)
                model.message = nil
            }
        }
    }
    private func checkServer() {
        perform {
            discovery.stop()
            let validated = try URLPolicy.validate(url, allowDevelopmentHTTP: allowHTTP)
            checkedURL = validated.absoluteString
            url = validated.absoluteString
            try await model.probe(url: url, allowHTTP: allowHTTP)
            step = .trust
        }
    }
    private func requestPin() {
        perform {
            guard let approved = model.connection else {
                step = .server
                return
            }
            try await model.probe(url: approved.baseURL.absoluteString, allowHTTP: approved.allowDevelopmentHTTP)
            guard model.proposedConnection == approved else {
                step = .trust
                return
            }
            model.proposedConnection = nil
            let normalized = try LoginPinPolicy.email(email)
            let epoch = model.epoch
            let receipt = try await AuthSession.requestPin(connection: approved, email: normalized)
            try Task.checkCancellation()
            guard model.connection == approved, model.epoch == epoch else { throw CancellationError() }
            requestedEmail = normalized
            email = normalized
            pin = ""
            pinExpiry = Date().addingTimeInterval(TimeInterval(receipt.expiresIn))
            step = .enterPin
        }
    }
    private func signIn() {
        perform {
            guard let requestedEmail, let pinExpiry, pinExpiry > Date() else {
                resetPinRequest()
                throw LoginPinError.expiredRequest
            }
            guard pin.count == 8 else { throw ClientError.invalid("Enter the 8-digit PIN.") }
            if await model.login(email: requestedEmail, pin: pin) {
                pin = ""
                if model.needsOnboarding { resumeSetup() }
            } else if let message = model.message {
                throw ClientError.invalid(message)
            } else {
                notice = "Sign-in was cancelled. You can try again."
            }
        }
    }
    private func editServer() {
        perform {
            resetPinRequest()
            try await model.beginServerChange()
            step = .server
        }
    }
    private func back() {
        failure = nil
        notice = nil
        switch step {
        case .trust, .signIn: editServer()
        case .enterPin: resetPinRequest()
        case .photos: step = .library
        case .ready: step = backup ? .photos : .library
        default: break
        }
    }
    private func resetPinRequest() {
        requestedEmail = nil
        pinExpiry = nil
        pin = ""
        step = .signIn
    }
    private func loadLibraries(reset: Bool = false) {
        perform { try await model.loadLibraries(reset: reset) }
    }
    private func resumeSetup() {
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
    private func finish() {
        perform {
            guard let selectedLibrary else { throw ClientError.invalid("Choose a library.") }
            try await model.completeOnboarding(library: selectedLibrary, backup: backup, allowCellular: !wifiOnly)
        }
    }
    private func openSettings() {
        guard let settings = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settings) { opened in
            if !opened { failure = OnboardingFailure(ClientError.invalid("Unable to open iPhone Settings.")) }
        }
    }
}

#if UI_QUALIFICATION
    extension OnboardingView {
        init(qualificationModel model: AppModel, step: Int) {
            precondition(Bundle.main.bundleIdentifier == "app.nephos.ui-qualification")
            self.init(model: model)
            _step = State(initialValue: Step(rawValue: step) ?? .server)
            _url = State(initialValue: model.connection?.baseURL.absoluteString ?? "")
            _selectedLibrary = State(initialValue: model.libraries.first?.id)
            _permission = State(initialValue: model.photos.authorization)
            _initialized = State(initialValue: true)
        }
    }
#endif
