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
                if env["NEPHOS_UI_SCREEN"] == "qr-native-checks" {
                    try QRNativeQualification.checkPersistence()
                    window.rootViewController = UIHostingController(rootView: Text("QR native checks passed"))
                    return
                }
                if env["NEPHOS_UI_SCREEN"] == "qr-real-login" {
                    let model = AppModel()
                    if env["NEPHOS_QR_PHASE"] == "refresh", let saved = try Keychain.load() {
                        let session = AuthSession(credentials: saved)
                        _ = try await session.recoverAccessToken(rejected: saved.accessToken)
                    }
                    if env["NEPHOS_QR_PHASE"] != "discard-response" { await model.restore() }
                    if !model.signedIn, let image = env["NEPHOS_QR_IMAGE"], !image.isEmpty {
                        let raw = try QRImageDecoder.payload(Data(contentsOf: URL(fileURLWithPath: image)))
                        let qr = try EnrollmentQR.parse(raw)
                        if env["NEPHOS_QR_PHASE"] == "prepare" {
                            let connection = try await QREnrollmentClient.connection(for: qr)
                            _ = try Keychain.prepare(qr: qr, connection: connection)
                            window.rootViewController = UIHostingController(rootView: Text("QR request persisted"))
                            return
                        }
                        if env["NEPHOS_QR_PHASE"] == "discard-response" {
                            let pending = try Keychain.vault().pending
                            guard let pending else { throw QREnrollmentError.invalidProof }
                            _ = try await QREnrollmentClient.exchange(pending)
                            window.rootViewController = UIHostingController(
                                rootView: Text("QR response deliberately lost"))
                            return
                        }
                        try await model.enroll(qr: qr)
                    }
                    guard model.signedIn, let api = model.api else {
                        throw ClientError.invalid(model.message ?? "Real QR session did not restore.")
                    }
                    let page = try await api.libraries()
                    guard let library = page.items.first else {
                        throw ClientError.invalid("The real QR fixture account has no accessible library.")
                    }
                    _ = try await api.assets(library: library.id, cursor: nil)
                    try await model.loadLibraries(reset: true)
                    window.rootViewController = UIHostingController(rootView: RootView(model: model))
                    return
                }
                if env["NEPHOS_UI_SCREEN"] == "trash-native" {
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.protocolClasses = [TrashQualificationProtocol.self]
                    let session = URLSession(configuration: configuration, delegate: HTTP.delegate, delegateQueue: nil)
                    let connection = Connection(
                        baseURL: URL(string: "http://trash-qualification.invalid")!,
                        config: ServerConfig(
                            serverId: "trash-fixture", issuer: "https://identity.invalid", clientId: "fixture",
                            maxUploadBytes: 1000, chunkSize: 100), allowDevelopmentHTTP: true)
                    let model = AppModel(
                        qualificationAPI: API(
                            connection: connection, auth: QualificationTokens("fixture-only"), session: session),
                        subject: "trash-fixture",
                        library: Library(id: TrashQualificationProtocol.library, name: "Trash fixture"))
                    await model.restore()
                    try await qualifyTrash(model)
                    window.rootViewController = UIHostingController(rootView: RootView(model: model))
                    try report(["ready": true, "screen": "trash-native", "checks": 14, "realAPI": false])
                    return
                }
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
                    await model.restore()
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
                    NetworkPolicy.shared.qualificationNetwork()
                    model.photos.qualificationThumbnail = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 360))
                        .image { context in
                            UIColor.systemTeal.setFill()
                            context.fill(CGRect(x: 0, y: 0, width: 360, height: 360))
                            UIColor.systemYellow.setFill()
                            context.cgContext.fillEllipse(in: CGRect(x: 220, y: 40, width: 70, height: 70))
                            UIColor.systemGreen.setFill()
                            let mountain = UIBezierPath()
                            mountain.move(to: CGPoint(x: 0, y: 360))
                            mountain.addLine(to: CGPoint(x: 150, y: 110))
                            mountain.addLine(to: CGPoint(x: 360, y: 360))
                            mountain.close()
                            mountain.fill()
                        }
                    if env["NEPHOS_UI_SCREEN"] == "backup-people" {
                        let page = RemoteList<FacePerson, UUID>()
                        var acceptedName = ""
                        let personID = UUID()
                        let stale = Task {
                            await page.load(
                                reset: true, model: model, onLoaded: { acceptedName = "stale name" }
                            ) { _ in
                                try await Task.sleep(for: .milliseconds(100))
                                return (
                                    [FacePerson(id: personID, name: "stale name", aliases: [], redirectId: nil)], nil
                                )
                            }
                        }
                        try await Task.sleep(for: .milliseconds(20))
                        await page.load(reset: true, model: model, onLoaded: { acceptedName = "current name" }) { _ in
                            return ([FacePerson(id: personID, name: "current name", aliases: [], redirectId: nil)], nil)
                        }
                        await stale.value
                        guard acceptedName == "current name", page.items.first?.name == "current name" else {
                            throw ClientError.invalid("A stale People request overwrote the accepted name.")
                        }
                        window.rootViewController = UIHostingController(
                            rootView: NavigationStack { PeopleView(model: model) })
                        try report(["ready": true, "screen": "backup-people", "realAPI": false])
                        return
                    }
                    if env["NEPHOS_UI_SCREEN"] == "backup-publication" {
                        NetworkPolicy.shared.qualificationNetwork(constrained: true)
                        var record = model.ledger.records[0]
                        let group = ResourceSetRecord(
                            id: UUID(), libraryId: library.id, source: record.source, kind: "single")
                        record.resourceSetId = group.id
                        record.resourceRole = "photo"
                        record.uniformTypeIdentifier = "public.jpeg"
                        record.phase = .ready
                        record.evidence = BackupEvidence(
                            id: record.id, sha256: record.sha256, size: record.size, available: true, createdAt: "")
                        model.ledger.records[0] = record
                        model.ledger.resourceSets = [group]
                        model.ledger.records[0].nextRetryAt = Date().addingTimeInterval(300)
                        await model.runBackup()
                        guard model.ledger.resourceSets?[0].manifest == nil else {
                            throw ClientError.invalid("Metadata publication bypassed a required original's backoff.")
                        }
                        model.ledger.records[0].nextRetryAt = nil
                    }
                    if env["NEPHOS_UI_SCREEN"] == "backup-gallery" {
                        try await qualifyGallery(model)
                        if env["NEPHOS_UI_PREVIEW_REGRESSION"] == "1" {
                            model.photos.qualificationGalleryAssets = [
                                LocalGalleryAsset(
                                    identifier: "fixture-0", date: Date(timeIntervalSince1970: 1_790_000_255),
                                    isVideo: false)
                            ]
                            var record = BackupQualificationProtocol.records[0]
                            record.phase = .ready
                            record.assetId = UUID(uuidString: "00000000-0000-0000-0000-000000000251")!
                            model.ledger.records = [record]
                        }
                        window.rootViewController = UIHostingController(
                            rootView: QualificationGalleryHost(model: model))
                        Task {
                            try await Task.sleep(
                                for: .seconds(
                                    env["NEPHOS_UI_SCROLL_REGRESSION"] == "1"
                                        || env["NEPHOS_UI_PREVIEW_REGRESSION"] == "1" ? 12 : 3))
                            BackupQualificationProtocol.setRevision(2)
                        }
                        try report(["ready": true, "screen": "backup-gallery", "realAPI": false])
                        return
                    }
                    window.rootViewController = UIHostingController(
                        rootView: NavigationStack { BackupView(model: model) })
                    if env["NEPHOS_UI_SCREEN"] == "backup-startup" {
                        model.scheduleAutomaticRun()
                        try await Task.sleep(for: .milliseconds(100))
                        await model.setBackupPaused(true)
                    }
                    try report(["ready": true, "screen": env["NEPHOS_UI_SCREEN"]!, "realAPI": false])
                    return
                }
                if env["NEPHOS_UI_SCREEN"] == "onboarding-flow" {
                    let model = AppModel()
                    if env["NEPHOS_UI_SEED_LEGACY"] == "1" {
                        await model.restore()
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
                        rootView: RootView(model: model).modifier(AppAppearanceModifier())
                            .task {
                                if env["NEPHOS_UI_RESTORE_DELAY"] == "1" {
                                    try? await Task.sleep(for: .seconds(5))
                                }
                                await model.restore()
                            })
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
                await model.restore()
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
                    try await model.saveOnboarding(draft)
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
                if ProcessInfo.processInfo.environment["NEPHOS_UI_SCREEN"] == "qr-real-login" {
                    let code: String
                    if let error = error as? QREnrollmentError {
                        code = error.rawValue
                    } else if let error = error as? URLError {
                        code = "url:\(error.code.rawValue)"
                    } else if let error = error as? DecodingError {
                        switch error {
                        case .keyNotFound(let key, _): code = "decode.key:\(key.stringValue)"
                        case .typeMismatch: code = "decode.type"
                        case .valueNotFound: code = "decode.value"
                        case .dataCorrupted: code = "decode.corrupt"
                        @unknown default: code = "decode.unknown"
                        }
                    } else if case ClientError.http(let status, _) = error {
                        code = "http:\(status)"
                    } else if case ClientError.invalid(let detail) = error {
                        code =
                            "invalid:"
                            + detail.components(separatedBy: .alphanumerics.inverted)
                            .filter { !$0.isEmpty }.prefix(12).joined(separator: "_")
                    } else {
                        code = "unexpected"
                    }
                    window.rootViewController = UIHostingController(rootView: Text("QR_ERROR=\(code)"))
                    return
                }
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

    private func qualifyGallery(_ model: AppModel) async throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw ClientError.invalid("Gallery qualification: \(message)") }
        }
        model.ledger.records = []
        model.libraries[0].isShared = true
        model.ledger.settings.backupPaused = true
        model.isLoadingGallery = false
        await model.loadGallery(reset: true, newest: true)
        for _ in 0..<3 { await model.loadGallery() }
        try require(model.gallery.items.count == 200, "Initial four-page window was not loaded.")
        let anchor = model.gallery.items[150].id
        model.rememberAnchor(anchor)
        model.scrollTarget = nil
        await model.flushPersistence()
        model.galleryAtTop = false
        BackupQualificationProtocol.setRevision(2)
        await model.loadGallery(reset: true, automatic: true)
        try require(
            model.gallery.items.count == 200 && model.visibleAnchor == anchor && model.scrollTarget == nil,
            "Automatic refresh lost the loaded window or issued an unsolicited scroll.")
        let requests = BackupQualificationProtocol.assetPageCount
        await model.loadGallery(reset: true, automatic: true)
        try require(
            BackupQualificationProtocol.assetPageCount == requests && model.visibleAnchor == anchor
                && model.scrollTarget == nil,
            "Unchanged snapshot refetched pages or issued an unsolicited scroll.")
        model.galleryAtTop = true
        BackupQualificationProtocol.setRevision(3)
        await model.loadGallery(reset: true, automatic: true)
        try require(model.scrollTarget == model.gallery.items.first?.id, "Newest view did not follow new media.")
        model.retainedGallery = nil
        model.gallery.reset()
        model.visibleAnchor = nil
        model.scrollTarget = nil
        BackupQualificationProtocol.setRevision(1)
    }

    private func qualifyTrash(_ model: AppModel) async throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw ClientError.invalid("Trash qualification: \(message)") }
        }
        let ids = TrashQualificationProtocol.assets.map(\.id)
        model.ledger.settings.automaticBackup = false
        model.ledger.settings.onboardingCompleted = true
        await model.loadTrash(reset: true)
        try require(model.trashItems.count == 3 && model.trashLoadError == nil, "Owned trash did not load.")
        await model.restoreTrash([ids[0], ids[1]])
        try require(model.trashItems.map(\.id) == [ids[1], ids[2]], "Successful batch item remained in Trash.")
        try require(
            model.trashRestoreCompleted == 1 && model.trashRestoreFailures[ids[1]] != nil,
            "Partial batch failure was not explicit.")
        try require(model.gallery.items.contains { $0.id == ids[0] }, "Restored item did not reappear in gallery.")
        await model.restoreTrash(Set(model.trashRestoreFailures.keys))
        try require(
            model.trashItems.map(\.id) == [ids[2]] && model.trashRestoreFailures.isEmpty,
            "Retry did not restore only the failed resource.")
        await model.restoreTrash([ids[2]])
        try require(
            model.trashRestoreFailures[ids[2]]?.contains("deadline") == true,
            "Permanent-deletion conflict was not explained.")
        model.ledger.records = Array(TrashQualificationProtocol.assets.prefix(2).enumerated()).map { index, asset in
            var record = UploadRecord(
                id: asset.id, libraryId: asset.libraryId, fileName: asset.fileName, mediaType: asset.mediaType,
                size: asset.size, sha256: asset.sha256,
                source: SourceRevision(
                    localIdentifier: "trash-local-\(index)", modificationTime: 0, resourceNames: [asset.fileName],
                    resourceTypes: [1], pixelWidth: 10, pixelHeight: 10, duration: 0, cleanupSupported: false),
                resourceIndex: 0)
            record.phase = .ready
            record.assetId = asset.id
            return record
        }
        let account = try model.account.unwrap("No qualification account.")
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nephos/Accounts", isDirectory: true)
        TrashQualificationProtocol.configureLedger(root: root, account: account)
        // The uploaded mapping outside the currently loaded window must still be deleted.
        model.gallery.remove([ids[1]])
        let result = try await model.deleteMediaEverywhere(
            assetIDs: [], localIdentifiers: ["trash-local-0", "trash-local-1"])
        try require(
            result.deleted == [ids[0]] && result.failed[ids[1]] != nil,
            "Offscreen uploaded IDs or partial server deletion were lost.")
        try require(
            result.photosError != nil && result.removedLocal.isEmpty,
            "Unavailable Photos originals were falsely reported removed.")
        try require(
            TrashQualificationProtocol.suppressionWasDurable,
            "DELETE was sent before the source fence was persisted.")
        let restarted = try LedgerStore(root: root).load(account: account)
        try require(
            restarted.suppresses("trash-local-0", library: TrashQualificationProtocol.library)
                && restarted.suppresses("trash-local-1", library: TrashQualificationProtocol.library),
            "Partial deletion lost durable backup suppression.")
        TrashQualificationProtocol.enablePaging()
        await model.loadTrash(reset: true)
        try require(
            model.trashItems.map(\.id) == [ids[0]] && model.trashCursor != nil,
            "Trash did not retain its pagination cursor.")
        await model.restoreTrash([ids[0]])
        try require(
            model.trashItems.map(\.id) == [ids[2]] && model.trashCursor == nil,
            "Restoring the loaded page falsely showed empty Trash instead of loading older items.")
        try require(
            !TrashQualificationProtocol.requestedOriginal,
            "Marker-only restore downloaded an original or uploaded media.")
        try await model.signOut()
        try require(
            model.trashItems.isEmpty && model.trashRestoreFailures.isEmpty,
            "Sign-out retained another account's trash state.")
    }
}

extension Optional {
    fileprivate func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw ClientError.invalid(message) }
        return value
    }
}

private final class TrashQualificationProtocol: URLProtocol {
    static let library = UUID()
    static let assets = (0..<3).map { index in
        Asset(
            id: UUID(), libraryId: library, fileName: "trash-fixture-\(index).jpg", mediaType: "image/jpeg",
            size: 100, sha256: String(repeating: "a", count: 64),
            createdAt: "2026-11-01T12:00:00Z", hasPreview: false)
    }
    private static let lock = NSLock()
    private static var deleted = Set(assets.map(\.id))
    private static var restoreAttempts: [UUID: Int] = [:]
    private static var revision: Int64 = 1
    private static var ledgerRoot: URL?
    private static var account: String?
    private static var durable = false
    private static var original = false
    private static var paging = false
    static var suppressionWasDurable: Bool { lock.withLock { durable } }
    static var requestedOriginal: Bool { lock.withLock { original } }
    static func configureLedger(root: URL, account: String) {
        lock.withLock {
            ledgerRoot = root
            self.account = account
        }
    }
    static func enablePaging() { lock.withLock { paging = true } }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "trash-qualification.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let response: (Int, Data) = try Self.lock.withLock {
                let path = request.url?.path ?? ""
                if path.contains("/original") || path.contains("/uploads") { Self.original = true }
                if path == "/v1/trash" {
                    let items = Self.assets.filter { Self.deleted.contains($0.id) }.map {
                        TrashItem(asset: $0, deletedAt: "2026-11-01T12:00:00Z", purgeAfter: "2026-12-01T12:00:00Z")
                    }
                    let before = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                        .queryItems?.first { $0.name == "before" }?.value
                    let paged = Self.paging && before == nil && items.count > 1
                    return (
                        200,
                        try JSONEncoder().encode(
                            TrashPage(
                                items: paged ? Array(items.prefix(1)) : items,
                                nextCursor: paged
                                    ? items.first.map { TrashCursor(deletedAt: $0.deletedAt, id: $0.id) } : nil))
                    )
                }
                if path.hasSuffix("/restore"), let component = request.url?.pathComponents.dropLast().last,
                    let id = UUID(uuidString: component)
                {
                    Self.restoreAttempts[id, default: 0] += 1
                    if id == Self.assets[2].id { return (409, Data()) }
                    if id == Self.assets[1].id && Self.restoreAttempts[id] == 1 { return (503, Data()) }
                    Self.deleted.remove(id)
                    Self.revision += 1
                    return (204, Data())
                }
                if request.httpMethod == "DELETE", let component = request.url?.lastPathComponent,
                    let id = UUID(uuidString: component)
                {
                    let root = try Self.ledgerRoot.unwrap("Missing ledger root.")
                    let account = try Self.account.unwrap("Missing ledger account.")
                    let ledger = try LedgerStore(root: root).load(account: account)
                    Self.durable =
                        ledger.suppresses("trash-local-0", library: Self.library)
                        && ledger.suppresses("trash-local-1", library: Self.library)
                        && ledger.records.allSatisfy { $0.remoteRemoved == true }
                    if id == Self.assets[1].id { return (503, Data()) }
                    Self.deleted.insert(id)
                    Self.revision += 1
                    return (204, Data())
                }
                if path.hasSuffix("/snapshots") {
                    return (
                        200,
                        try JSONEncoder().encode(
                            GallerySnapshot(
                                id: UUID(), revision: Self.revision, accessGeneration: 1,
                                expiresAt: "2099-01-01T00:00:00Z",
                                totalCount: Int64(Self.assets.filter { !Self.deleted.contains($0.id) }.count)))
                    )
                }
                if path.contains("/snapshots/") && path.hasSuffix("/assets") {
                    return (
                        200,
                        try JSONEncoder().encode(
                            AssetPage(
                                items: Self.assets.filter { !Self.deleted.contains($0.id) }, nextCursor: nil))
                    )
                }
                if path.hasSuffix("/changes") { return (410, Data()) }
                return (404, Data())
            }
            let http = try HTTPURLResponse(
                url: request.url!, statusCode: response.0, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ).unwrap("Missing HTTP fixture response.")
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            if !response.1.isEmpty { client?.urlProtocol(self, didLoad: response.1) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private final class BackupQualificationProtocol: URLProtocol {
    static let library = UUID()
    static let screen = ProcessInfo.processInfo.environment["NEPHOS_UI_SCREEN"]
    static let records: [UploadRecord] =
        (0..<(screen == "backup-parallel"
        ? 6 : ["backup-attention", "backup-publication"].contains(screen ?? "") ? 2 : 1))
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
    private static var revision: Int64 = 1
    private static var pageCount = 0
    private static let namedPerson = UUID()
    private static let unnamedPerson = UUID()
    private static var sourceName = "Source person"
    private static var destinationName: String?
    private static var merged = false
    static var assetPageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pageCount
    }
    static func setRevision(_ value: Int64) {
        lock.lock()
        defer { lock.unlock() }
        revision = value
    }
    private static func galleryAsset(_ index: Int) -> Asset {
        Asset(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
            libraryId: library,
            fileName: index == 251 ? "returned-photo.jpg" : index == 250 ? "new-photo.jpg" : "gallery-\(index).jpg",
            mediaType: "image/jpeg", size: 100, sha256: String(repeating: "a", count: 64),
            createdAt: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_790_000_000 + Double(index))),
            hasPreview: false)
    }
    private func peopleResponse() throws -> (status: Int, data: Data) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let path = request.url?.path else { throw ClientError.invalid("The fixture request has no URL.") }
        let source = FacePerson(
            id: Self.namedPerson, name: Self.sourceName, aliases: [],
            redirectId: Self.merged ? Self.unnamedPerson : nil)
        let target = FacePerson(id: Self.unnamedPerson, name: Self.destinationName, aliases: [], redirectId: nil)
        if path == "/v1/faces/people" {
            return (
                200,
                try JSONSerialization.data(
                    withJSONObject: [
                        "items": try (Self.merged ? [target] : [source, target]).map {
                            try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
                        }
                    ])
            )
        }
        if path == "/v1/faces/observations" || path.hasSuffix("/assets") {
            return (200, Data("{\"items\":[]}".utf8))
        }
        if path.hasSuffix("/name"), request.httpMethod == "PUT" {
            let input = try JSONSerialization.jsonObject(with: requestData()) as? [String: Any]
            guard path.contains(Self.namedPerson.uuidString), let name = input?["name"] as? String else {
                throw ClientError.invalid("Unexpected People rename fixture request.")
            }
            Self.sourceName = name
            return (204, Data())
        }
        if path.hasSuffix("/merge"), request.httpMethod == "POST" {
            let input = try JSONDecoder().decode([String: UUID].self, from: requestData())
            guard path.contains(Self.namedPerson.uuidString), input["targetId"] == Self.unnamedPerson else {
                throw ClientError.invalid("Unexpected People merge fixture request.")
            }
            Self.merged = true
            Self.destinationName = Self.sourceName
            return (204, Data())
        }
        if path == "/v1/faces/people/\(Self.namedPerson)" { return (200, try JSONEncoder().encode(source)) }
        if path == "/v1/faces/people/\(Self.unnamedPerson)" { return (200, try JSONEncoder().encode(target)) }
        throw ClientError.invalid("Unexpected People fixture route: \(path)")
    }
    private var pending = false
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "backup-qualification.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let status: Int
            let data: Data
            if Self.screen == "backup-gallery" {
                respond(status: 200, data: try galleryResponse())
                return
            } else if Self.screen == "backup-people" {
                let response = try peopleResponse()
                respond(status: response.status, data: response.data)
                return
            } else if request.httpMethod == "PUT", request.url?.path.contains("/resource-sets/") == true {
                let intent = try JSONDecoder().decode(ResourceSetIntent.self, from: requestData())
                guard let component = request.url?.lastPathComponent, let id = UUID(uuidString: component) else {
                    throw ClientError.invalid("Missing fixture set ID.")
                }
                respond(
                    status: 200,
                    data: try JSONEncoder().encode(
                        ResourceManifest(
                            id: id, libraryId: Self.library, kind: intent.kind, sourceRevision: intent.sourceRevision,
                            primaryAssetId: intent.primaryAssetId, resources: intent.resources, createdAt: "")))
                return
            } else if request.url?.path == "/v1/uploads", request.httpMethod == "POST" {
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
    private func galleryResponse() throws -> Data {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let encoder = JSONEncoder()
        let path = request.url!.path
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if path.hasSuffix("/snapshots") {
            return try encoder.encode(
                GallerySnapshot(
                    id: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", Self.revision))!,
                    revision: Self.revision, accessGeneration: 1, expiresAt: "2099-01-01T00:00:00Z",
                    totalCount: 249 + Self.revision))
        }
        if path.hasSuffix("/assets") {
            Self.pageCount += 1
            let before = query.first { $0.name == "before" }?.value
            let beforeID = query.first { $0.name == "beforeId" }?.value?.lowercased()
            let assets = (0..<Int(249 + Self.revision)).reversed().map(Self.galleryAsset).filter {
                before == nil || $0.createdAt < before!
                    || ($0.createdAt == before && $0.id.uuidString.lowercased() < (beforeID ?? ""))
            }
            let items = Array(assets.prefix(50))
            return try encoder.encode(
                AssetPage(
                    items: items,
                    nextCursor: assets.count > 50
                        ? items.last.map { GalleryCursor(createdAt: $0.createdAt, id: $0.id) } : nil))
        }
        if path.hasSuffix("/changes"), let after = query.first(where: { $0.name == "after" })?.value.flatMap(Int64.init)
        {
            return try encoder.encode(
                GalleryChanges(
                    fromRevision: after, toRevision: Self.revision, targetRevision: Self.revision, hasMore: false,
                    changes: [
                        GalleryRevision(
                            revision: Self.revision,
                            items: [
                                GalleryChange(
                                    operation: "upsert", assetId: Self.galleryAsset(250).id,
                                    asset: Self.galleryAsset(250))
                            ])
                    ]))
        }
        if path.hasSuffix("/timeline") { return try encoder.encode(TimelinePage(items: [])) }
        throw ClientError.http(404, "Fixture preview unavailable.")
    }
    private func requestData() throws -> Data {
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
        return body
    }
    private func requestedRecord() throws -> UploadRecord {
        struct Identity: Decodable { let id: UUID }
        let id = try JSONDecoder().decode(Identity.self, from: requestData()).id
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

private struct QualificationGalleryHost: View {
    let model: AppModel
    @State private var phase: ScenePhase = .active
    var body: some View {
        GalleryView(model: model)
            .safeAreaInset(edge: .bottom) {
                if ProcessInfo.processInfo.environment["NEPHOS_UI_PREVIEW_REGRESSION"] == "1" {
                    Button("Refresh previews") {
                        model.photos.qualificationThumbnailDelay = .seconds(3)
                        model.photosGeneration = UUID()
                    }
                }
            }
            .environment(\.scenePhase, phase)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                phase = .inactive
                BackupQualificationProtocol.setRevision(3)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                phase = .active
            }
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
