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
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        window.rootViewController = UIHostingController(rootView: ProgressView("Connecting isolated test account…"))
        window.makeKeyAndVisible()
        Task {
            do {
                let env = ProcessInfo.processInfo.environment
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
