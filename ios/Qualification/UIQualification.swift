import BackgroundTasks
import SwiftUI
import UIKit

@MainActor
private final class QualificationTokens: AccessTokenProviding {
    let value: String
    init(_ value: String) { self.value = value }
    func accessToken() async throws -> String { value }
}

@main
@MainActor
final class UIQualification: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if ProcessInfo.processInfo.environment["NEPHOS_UI_SCREEN"]?.hasPrefix("backup-") == true {
            let registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: AppModel.backgroundID, using: nil
            ) { task in task.setTaskCompleted(success: false) }
            precondition(registered, "The isolated backup host could not register its background task.")
        }
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        window.rootViewController = UIHostingController(rootView: ProgressView("Connecting isolated test account…"))
        window.makeKeyAndVisible()
        Task {
            do {
                let env = ProcessInfo.processInfo.environment
                if env["NEPHOS_UI_SCREEN"]?.hasPrefix("backup-") == true {
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.protocolClasses = [BackupQualificationProtocol.self]
                    let session = URLSession(configuration: configuration, delegate: HTTP.delegate, delegateQueue: nil)
                    let library = Library(id: BackupQualificationProtocol.library, name: "Isolated retry fixture")
                    let connection = Connection(
                        baseURL: URL(string: "http://backup-qualification.invalid")!,
                        config: ServerConfig(
                            serverId: "fixture", issuer: "https://identity.invalid", clientId: "fixture",
                            maxUploadBytes: 1000, chunkSize: 100), allowDevelopmentHTTP: true)
                    let model = AppModel(
                        qualificationAPI: API(
                            connection: connection, auth: QualificationTokens("fixture-only"), session: session),
                        subject: "retry-fixture", library: library)
                    model.ledger.records = BackupQualificationProtocol.records
                    if env["NEPHOS_UI_SCREEN"] == "backup-attention" {
                        for index in model.ledger.records.indices {
                            model.ledger.records[index].phase = .paused
                            model.ledger.records[index].requiresUserAction = true
                            model.ledger.records[index].error =
                                "Server returned 400. Try again when the server is available."
                        }
                    }
                    model.ledger.settings.automaticBackup = false
                    model.ledger.settings.onboardingCompleted = true
                    model.ledger.settings.allowCellular = true
                    model.isLoadingGallery = true
                    window.rootViewController = UIHostingController(
                        rootView: NavigationStack { BackupView(model: model) })
                    try report(["ready": true, "screen": env["NEPHOS_UI_SCREEN"]!, "realAPI": false])
                    return
                }
                if env["NEPHOS_UI_SCREEN"] == "onboarding-flow" {
                    let model = AppModel()
                    if env["NEPHOS_UI_SEED_LEGACY"] == "1" {
                        let old = Connection(
                            baseURL: URL(string: "http://192.168.1.10:18080")!,
                            config: ServerConfig(
                                serverId: "legacy-fixture", issuer: "http://localhost:18081/realms/nephos",
                                clientId: "nephos-ios", maxUploadBytes: 8_589_934_592, chunkSize: 4_194_304),
                            allowDevelopmentHTTP: true)
                        model.proposedConnection = old
                        await model.approveConnection()
                        guard model.connection == old else {
                            throw ClientError.invalid(
                                "Could not persist the isolated legacy fixture: \(model.message ?? "unknown error")")
                        }

                        UserDefaults.standard.removeObject(forKey: "onboardingCheckedURL")
                    }
                    window.rootViewController = UIHostingController(
                        rootView: RootView(model: model).modifier(AppAppearanceModifier()))
                    try report(["ready": true, "screen": "onboarding-flow"])
                    return
                }
                guard let token = env["NEPHOS_E2E_BEARER"],
                    let subject = env["NEPHOS_E2E_SUBJECT"],
                    let libraryID = env["NEPHOS_E2E_LIBRARY"].flatMap(UUID.init(uuidString:)),
                    let assetID = env["NEPHOS_E2E_ASSETS"]?.split(separator: ",").first.flatMap({
                        UUID(uuidString: String($0))
                    })
                else { throw ClientError.invalid("The qualification account is incomplete.") }
                let base = try URLPolicy.validate(
                    env["NEPHOS_UI_BASE_URL"] ?? "http://localhost:18080", allowDevelopmentHTTP: true)
                let config = try await HTTP.json(
                    ServerConfig.self, HTTP.request(base.appendingPathComponent("v1/config")))
                let api = API(
                    connection: Connection(baseURL: base, config: config, allowDevelopmentHTTP: true),
                    auth: QualificationTokens(token))
                let libraries = try await api.libraries()
                guard let library = libraries.items.first(where: { $0.id == libraryID }) else {
                    throw ClientError.invalid("The real fixture library was not authorized.")
                }
                let model = AppModel(qualificationAPI: api, subject: subject, library: library)
                await model.loadGallery(reset: true)
                guard model.gallery.items.count == 2 else {
                    throw ClientError.invalid(model.message ?? "The fixture gallery did not load both originals.")
                }
                let asset = try await api.asset(assetID)
                let observations = try await api.observations(asset: assetID)
                guard let personID = observations.items.first?.personId else {
                    throw ClientError.invalid("Real inference did not return a person.")
                }
                let person = try await api.person(personID)
                let screen = env["NEPHOS_UI_SCREEN"] ?? "gallery"
                if screen.hasPrefix("onboarding-") {
                    model.ledger.settings.onboardingCompleted = false
                    try await model.probe(url: base.absoluteString, allowHTTP: true)
                    guard model.proposedConnection?.config == config else {
                        throw ClientError.invalid("Preflight changed the real fixture identity.")
                    }
                    let draft = OnboardingDraft(libraryID: library.id, backup: false, allowCellular: false, ready: true)
                    try model.saveOnboarding(draft)
                    if screen == "onboarding-5" {
                        try await model.completeOnboarding(library: library.id, backup: false, allowCellular: false)
                        guard !model.needsOnboarding, !model.ledger.settings.automaticBackup,
                            !model.ledger.settings.automaticCleanup
                        else { throw ClientError.invalid("Browse-only setup enabled background backup or cleanup.") }
                    }
                }
                UserDefaults.standard.set(env["NEPHOS_UI_THEME"] ?? "system", forKey: "appearance")
                window.rootViewController = UIHostingController(
                    rootView: QualificationScreen(model: model, asset: asset, person: person, screen: screen)
                        .modifier(AppAppearanceModifier()))
                try report(["ready": true, "screen": screen, "realAPI": true])
            } catch {
                window.rootViewController = UIHostingController(rootView: Text(error.localizedDescription).padding())
                do { try report(["ready": false, "error": error.localizedDescription]) } catch {
                    NSLog("Qualification report could not be written.")
                }
            }
        }
        return true
    }
    private func report(_ values: [String: Any]) throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try JSONSerialization.data(withJSONObject: values).write(
            to: directory.appendingPathComponent("ui-report.json"), options: .atomic)
    }
}

private final class BackupQualificationProtocol: URLProtocol {
    static let library = UUID()
    static let screen = ProcessInfo.processInfo.environment["NEPHOS_UI_SCREEN"]
    static let records: [UploadRecord] = (0..<(screen == "backup-parallel" ? 6 : screen == "backup-attention" ? 2 : 1))
        .map {
            UploadRecord(
                id: UUID(), libraryId: library, fileName: "retry-fixture-\($0).jpg", mediaType: "image/jpeg",
                size: 100, sha256: String(repeating: "a", count: 64),
                source: SourceRevision(
                    localIdentifier: "fixture-\($0)", modificationTime: 0, resourceNames: ["retry-fixture-\($0).jpg"],
                    resourceTypes: [1], pixelWidth: 10, pixelHeight: 10, duration: 0, cleanupSupported: false),
                resourceIndex: 0)
        }
    private static let lock = NSLock()
    private static var attempts = 0
    private static var inFlight = 0
    private static var peak = 0
    private var pending = false
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "backup-qualification.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let status: Int
            let data: Data
            if request.url?.path == "/v1/uploads", request.httpMethod == "POST" {
                let record = try requestedRecord()
                Self.lock.lock()
                Self.attempts += 1
                let attempt = Self.attempts
                if Self.screen == "backup-parallel" {
                    pending = true
                    Self.inFlight += 1
                    Self.peak = max(Self.peak, Self.inFlight)
                }
                Self.lock.unlock()
                status = Self.screen == "backup-retry" && attempt == 1 ? 503 : 200
                data = try JSONEncoder().encode(
                    UploadStatus(
                        id: record.id, state: "ready", chunkSize: 100, receivedParts: [0],
                        assetId: record.id, error: nil))
                if Self.screen == "backup-parallel" {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        guard self.endPending() else { return }
                        self.respond(status: status, data: data)
                    }
                    return
                }
            } else if let record = Self.records.first(where: {
                request.url?.path.lowercased() == "/v1/assets/\($0.id)/backup".lowercased()
            }) {
                status = 200
                Self.lock.lock()
                let overlappedCorrectly = Self.screen != "backup-parallel" || Self.peak == 3
                Self.lock.unlock()
                data = try JSONEncoder().encode(
                    BackupEvidence(
                        id: record.id, sha256: record.sha256, size: record.size,
                        available: overlappedCorrectly, createdAt: "2026-10-31T00:00:00Z"))
            } else {
                throw ClientError.invalid("Unexpected qualification request: \(request.url?.path ?? "nil")")
            }
            respond(status: status, data: data)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    private func requestedRecord() throws -> UploadRecord {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw ClientError.invalid("Fixture request body could not be read.") }
                if count == 0 { break }
                body.append(contentsOf: buffer.prefix(count))
                guard body.count <= 65_536 else { throw ClientError.invalid("Fixture request body is too large.") }
            }
        }
        struct Identity: Decodable { let id: UUID }
        let id = try JSONDecoder().decode(Identity.self, from: body).id
        guard let record = Self.records.first(where: { $0.id == id }) else {
            throw ClientError.invalid("Unknown fixture upload.")
        }
        return record
    }
    private func respond(status: Int, data: Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    private func endPending() -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard pending else { return false }
        pending = false
        Self.inFlight -= 1
        return true
    }
    override func stopLoading() { _ = endPending() }
}

private struct QualificationScreen: View {
    let model: AppModel
    let asset: Asset
    let person: FacePerson
    let screen: String
    var body: some View {
        Group {
            switch screen {
            case "onboarding-0", "onboarding-1", "onboarding-2", "onboarding-3", "onboarding-4", "onboarding-5":
                OnboardingView(qualificationModel: model, step: Int(screen.suffix(1))!)
            case "people": NavigationStack { PeopleView(model: model) }
            case "history": NavigationStack { CorrectionsView(model: model) }
            case "person": NavigationStack { PersonView(model: model, person: person) }
            case "photo": NavigationStack { OriginalView(asset: asset, model: model) }
            case "photo-people": NavigationStack { PhotoPeopleView(model: model, asset: asset) }
            case "settings": NavigationStack { SettingsView(model: model) }
            case "backup": NavigationStack { BackupView(model: model) }
            case "sharing": NavigationStack { SharingListView(model: model, received: false) }
            case "share":
                NavigationStack {
                    ShareComposer(
                        model: model,
                        selection: ShareSelection(
                            library: model.selectedLibrary!, assets: [asset.id]))
                }
            default: RootView(model: model)
            }
        }
    }
}
