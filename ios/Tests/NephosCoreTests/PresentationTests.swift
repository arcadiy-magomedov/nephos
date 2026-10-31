import CoreGraphics
import Foundation
import XCTest

@testable import NephosCore

final class PresentationTests: XCTestCase {
    func testServerAdvertisementsRequireSafeVersionedHTTPSAddresses() throws {
        let server = try ServerAdvertisement(name: "Nephos", version: "1", address: "https://Photos.local:18443/")
        XCTAssertEqual(server.url.absoluteString, "https://photos.local:18443")
        XCTAssertEqual(server.id, server.url.absoluteString)
        for address in [
            "http://photos.local", "https://user:password@photos.local", "https://photos.local?token=x",
            "https://photos.local?", "https://photos.local#", "https://localhost", "https://localhost.",
            "https://127.0.0.1", "https://[::1]", "https://0.0.0.0", "https://[::]",
            "https://photos.local:0", "https://photos.local:65536", "https://photos.local\n",
            "https://photos.local/" + String(repeating: "x", count: 252),
        ] {
            XCTAssertThrowsError(try ServerAdvertisement(name: "Nephos", version: "1", address: address), address)
        }
        for name in ["", " ", "bad\nname", String(repeating: "\u{1F600}", count: 16)] {
            XCTAssertThrowsError(try ServerAdvertisement(name: name, version: "1", address: "https://photos.local"))
        }
        XCTAssertThrowsError(try ServerAdvertisement(name: "Nephos", version: "2", address: "https://photos.local"))
        XCTAssertThrowsError(try ServerAdvertisement(name: "Nephos", version: "", address: "https://photos.local"))
    }

    func testChangedDraftAndOldLoopbackIssuerCannotReuseApprovedServer() {
        let old = Connection(
            baseURL: URL(string: "http://192.168.1.10:18080")!,
            config: ServerConfig(
                serverId: "fixture", issuer: "http://localhost:18081/realms/nephos",
                clientId: "nephos-ios", maxUploadBytes: 100, chunkSize: 4_194_304),
            allowDevelopmentHTTP: true)
        XCTAssertTrue(OnboardingPolicy.requiresServerReview(old, draftURL: old.baseURL.absoluteString))
        let current = Connection(
            baseURL: URL(string: "https://photos.example.net")!,
            config: ServerConfig(
                serverId: "fixture", issuer: "https://photos.example.net/realms/nephos",
                clientId: "nephos-ios", maxUploadBytes: 100, chunkSize: 4_194_304),
            allowDevelopmentHTTP: false)
        XCTAssertFalse(OnboardingPolicy.requiresServerReview(current, draftURL: current.baseURL.absoluteString))
        XCTAssertTrue(OnboardingPolicy.requiresServerReview(current, draftURL: "https://other.example.net"))
    }

    func testOnboardingPreservesLegacyAccountsAndExplicitIncompleteState() throws {
        let settings = BackupSettings()
        XCTAssertFalse(OnboardingPolicy.completed(settings: settings, selectedLibrary: nil, hasResources: false))
        XCTAssertTrue(OnboardingPolicy.completed(settings: settings, selectedLibrary: UUID(), hasResources: false))
        XCTAssertTrue(OnboardingPolicy.completed(settings: settings, selectedLibrary: nil, hasResources: true))
        var incomplete = settings
        incomplete.onboardingCompleted = false
        XCTAssertFalse(OnboardingPolicy.completed(settings: incomplete, selectedLibrary: UUID(), hasResources: true))
        var ledger = AccountLedger()
        ledger.settings = incomplete
        ledger.onboarding = OnboardingDraft(libraryID: UUID(), backup: true, allowCellular: false, ready: false)
        let decoded = try JSONDecoder().decode(AccountLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(decoded.onboarding, ledger.onboarding)
        XCTAssertEqual(decoded.settings.onboardingCompleted, false)
        XCTAssertFalse(decoded.settings.automaticBackup)
        XCTAssertFalse(decoded.settings.automaticCleanup)
    }

    func testOnboardingRejectsRemoteServersAdvertisingLoopbackIdentity() throws {
        let server = URL(string: "https://photos.example.net")!
        for host in ["localhost", "auth.localhost", "127.0.0.1", "127.2.3.4", "[::1]"] {
            XCTAssertThrowsError(
                try OnboardingPolicy.validateIssuer(URL(string: "https://\(host)/realms/nephos")!, server: server))
        }
        XCTAssertNoThrow(
            try OnboardingPolicy.validateIssuer(URL(string: "https://auth.example.net/realms/nephos")!, server: server))
        XCTAssertNoThrow(
            try OnboardingPolicy.validateIssuer(
                URL(string: "http://localhost:18081")!, server: URL(string: "http://localhost:18080")!))
    }

    func testOnboardingDistinguishesCertificateAndIdentityFailures() {
        XCTAssertEqual(OnboardingFailure(URLError(.serverCertificateUntrusted)).title, "Certificate not trusted")
        XCTAssertTrue(
            OnboardingFailure(URLError(.serverCertificateUntrusted)).guidance.contains("Certificate Trust Settings"))
        XCTAssertEqual(OnboardingFailure(URLError(.cannotConnectToHost)).title, "Server unavailable")
        XCTAssertEqual(
            OnboardingFailure(URLError(.cannotConnectToHost), identity: true).title, "Sign-in server unavailable")
        let failure = OnboardingFailure(ClientError.invalid("Bad issuer"), identity: true)
        XCTAssertEqual(OnboardingFailure(failure).title, failure.title)
        XCTAssertEqual(OnboardingFailure(failure).detail, "Bad issuer")
    }

    private func asset(_ date: String, type: String = "image/heic", shared: String? = nil) -> Asset {
        Asset(
            id: UUID(), libraryId: UUID(), fileName: "fixture.heic", mediaType: type, size: 100,
            sha256: String(repeating: "a", count: 64), createdAt: date, hasPreview: true, sharedBy: shared)
    }

    func testAppearanceHasSystemDefaultAndExplicitOverrides() {
        XCTAssertEqual(AppAppearance.allCases, [.system, .light, .dark])
        XCTAssertEqual(AppAppearance(rawValue: "system"), .system)
        XCTAssertNil(AppAppearance(rawValue: "unsupported"))
    }

    func testChronologyUsesLocalDaysWithoutChangingAssets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -7 * 3600)!
        let first = asset("2026-10-31T00:30:00.123Z")
        let second = asset("2026-10-30T23:00:00Z", type: "video/quicktime")
        let third = asset("2026-10-31T20:00:00Z", shared: "Fixture owner")
        let unknown = asset("not-a-date")
        let days = MediaDay.groups([first, third, second, unknown], calendar: calendar)
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days[0].assets, [third])
        XCTAssertEqual(days[1].assets, [first, second])
        XCTAssertNil(days[2].date)
        XCTAssertEqual(MediaDay.groups([first, second, third], filter: .videos).flatMap(\.assets), [second])
        XCTAssertEqual(MediaDay.groups([first, second, third], filter: .shared).flatMap(\.assets), [third])
        XCTAssertEqual(MediaDay.groups([first, second], filter: .photos).flatMap(\.assets), [first])
    }

    func testFaceCropUsesUprightPreviewAndRejectsInvalidCoordinates() {
        func face(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> FaceObservation {
            FaceObservation(
                id: UUID(), assetId: UUID(), personId: nil, x: x, y: y, width: width,
                height: height, quality: "usable")
        }
        XCTAssertEqual(
            face(0.25, 0.1, 0.5, 0.5).cropRect(pixelWidth: 512, pixelHeight: 1000),
            CGRect(x: 128, y: 100, width: 256, height: 500))
        XCTAssertNotNil(face(0.5, 0.5, 0.5000001, 0.5).cropRect(pixelWidth: 512, pixelHeight: 512))
        for invalid in [face(-0.1, 0, 1, 1), face(0, 0, 2, 1), face(.nan, 0, 1, 1), face(0, 0, 0, 1)] {
            XCTAssertNil(invalid.cropRect(pixelWidth: 512, pixelHeight: 512))
        }
        XCTAssertNil(face(0, 0, 1, 1).cropRect(pixelWidth: 0, pixelHeight: 512))
    }

    func testPauseIsBackwardCompatibleAndIndependentOfAutomaticSettings() throws {
        let old = Data(
            #"{"automaticBackup":true,"automaticCleanup":false,"allowCellular":false,"cleanupWarningsAcknowledged":false}"#
                .utf8)
        var settings = try JSONDecoder().decode(BackupSettings.self, from: old)
        XCTAssertNil(settings.backupPaused)
        settings.backupPaused = true
        XCTAssertTrue(settings.automaticBackup)
        XCTAssertFalse(settings.automaticCleanup)
        XCTAssertEqual(try JSONDecoder().decode(BackupSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testShareScopeAndPersonInputValidation() throws {
        let library = UUID()
        let recipient = UUID().uuidString
        let id = UUID()
        XCTAssertNoThrow(
            try ShareInput(libraryId: library, recipientId: recipient, allAssets: false, assetIds: [id]).validate())
        XCTAssertNoThrow(
            try ShareInput(libraryId: library, recipientId: recipient, allAssets: true, assetIds: []).validate())
        for input in [
            ShareInput(libraryId: library, recipientId: recipient, allAssets: false, assetIds: []),
            ShareInput(libraryId: library, recipientId: recipient, allAssets: true, assetIds: [id]),
            ShareInput(libraryId: library, recipientId: recipient, allAssets: false, assetIds: [id, id]),
            ShareInput(libraryId: library, recipientId: "unknown", allAssets: false, assetIds: [id]),
        ] { XCTAssertThrowsError(try input.validate()) }
        XCTAssertNoThrow(try PersonNameInput(name: nil, aliases: []).validate())
        XCTAssertThrowsError(try PersonNameInput(name: String(repeating: "a", count: 121), aliases: []).validate())
        XCTAssertThrowsError(try PersonNameInput(name: "Name", aliases: [" "]).validate())
    }

    func testBackupCountsOnlyVerifiedCurrentLibraryResources() {
        let library = UUID()
        let source = SourceRevision(
            localIdentifier: "fixture", modificationTime: 0, resourceNames: [], resourceTypes: [],
            pixelWidth: 0, pixelHeight: 0, duration: 0, cleanupSupported: false)
        var record = UploadRecord(
            id: UUID(), libraryId: library, fileName: "fixture", mediaType: "image/jpeg", size: 100,
            sha256: String(repeating: "a", count: 64), source: source, resourceIndex: 0)
        var ledger = AccountLedger()
        ledger.records = [record]
        XCTAssertEqual(BackupProgress(ledger: ledger, library: library).pending, 1)
        record.phase = .ready
        ledger.records = [record]
        XCTAssertEqual(BackupProgress(ledger: ledger, library: library).verified, 0)
        record.evidence = BackupEvidence(
            id: record.id, sha256: record.sha256, size: 100, available: true, createdAt: "")
        ledger.records = [record]
        XCTAssertEqual(BackupProgress(ledger: ledger, library: library).fraction, 1)
        XCTAssertEqual(BackupProgress(ledger: ledger, library: UUID()).total, 0)
        record.remoteRemoved = true
        ledger.records = [record]
        XCTAssertEqual(BackupProgress(ledger: ledger, library: library).total, 0)
    }
}
