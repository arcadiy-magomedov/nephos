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
        if ProcessInfo.processInfo.environment["NEPHOS_UI_SCREEN"] == "backup-retry" {
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
                if env["NEPHOS_UI_SCREEN"] == "backup-retry" {
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
                    model.ledger.records = [BackupQualificationProtocol.record]
                    model.ledger.settings.automaticBackup = false
                    model.ledger.settings.onboardingCompleted = true
                    model.ledger.settings.allowCellular = true
                    model.isLoadingGallery = true
                    window.rootViewController = UIHostingController(
                        rootView: NavigationStack { BackupView(model: model) })
                    try report(["ready": true, "screen": "backup-retry", "realAPI": false])
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
    static let record = UploadRecord(
        id: UUID(), libraryId: library, fileName: "retry-fixture.jpg", mediaType: "image/jpeg",
        size: 100, sha256: String(repeating: "a", count: 64),
        source: SourceRevision(
            localIdentifier: "fixture", modificationTime: 0, resourceNames: ["retry-fixture.jpg"],
            resourceTypes: [1], pixelWidth: 10, pixelHeight: 10, duration: 0, cleanupSupported: false),
        resourceIndex: 0)
    private static let lock = NSLock()
    private static var attempts = 0
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "backup-qualification.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let status: Int
            let data: Data
            if request.url?.path == "/v1/uploads", request.httpMethod == "POST" {
                Self.lock.lock()
                Self.attempts += 1
                let attempt = Self.attempts
                Self.lock.unlock()
                status = attempt == 1 ? 503 : 200
                data = try JSONEncoder().encode(
                    UploadStatus(
                        id: Self.record.id, state: "ready", chunkSize: 100, receivedParts: [0],
                        assetId: Self.record.id, error: nil))
            } else if request.url?.path.lowercased() == "/v1/assets/\(Self.record.id)/backup".lowercased() {
                status = 200
                data = try JSONEncoder().encode(
                    BackupEvidence(
                        id: Self.record.id, sha256: Self.record.sha256, size: Self.record.size,
                        available: true, createdAt: "2026-10-31T00:00:00Z"))
            } else {
                throw ClientError.invalid("Unexpected qualification request: \(request.url?.path ?? "nil")")
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json", "Content-Length": String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
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
