import SwiftUI
import UIKit

@main
final class QualificationApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        let environment = ProcessInfo.processInfo.environment
        window.overrideUserInterfaceStyle = environment["NEPHOS_UI_THEME"] == "dark" ? .dark : .light
        window.rootViewController = UIHostingController(rootView: MediaStyle.background.ignoresSafeArea())
        window.makeKeyAndVisible()
        Task { @MainActor in
            do {
                try await showRequestedScreen(environment)
            } catch {
                show("QR_ERROR=\(errorCode(error))")
            }
        }
        return true
    }

    private func showRequestedScreen(_ environment: [String: String]) async throws {
        switch environment["NEPHOS_UI_SCREEN"] {
        case "generic-file-upload":
            guard let raw = environment["NEPHOS_FILE_UPLOAD_ORIGIN"], let origin = URL(string: raw) else {
                throw FileUploadError.invalid("Missing loopback upload fixture.")
            }
            try await FileUploadQualification.start(origin: origin)
            show("Generic file uploads queued")
        case "local-gallery":
            window?.rootViewController = UIHostingController(rootView: LocalGalleryQualification())
        case "qr-native-checks":
            try await Task.detached { try QRNativeQualification.checkPersistence() }.value
            show("QR native checks passed")
        case "qr-real-login":
            try await showRealLogin(environment)
        default:
            try await KeychainStorage().remove()
            let model = SignInModel()
            await model.restore()
            if environment["NEPHOS_UI_SCREEN"] == "invalid-qr" { await model.accept("not-a-nephos-code") }
            window?.rootViewController = UIHostingController(rootView: AppRootView(model: model))
        }
    }

    private func showRealLogin(_ environment: [String: String]) async throws {
        switch environment["NEPHOS_QR_PHASE"] {
        case "prepare":
            try await prepareRequest(environment)
            show("QR request persisted")
        case "discard-response":
            guard let pending = try await KeychainStorage().vault().pending else {
                throw QREnrollmentError.invalidProof
            }
            _ = try await QREnrollmentClient.exchange(pending)
            show("QR response deliberately lost")
        case "discard-refresh-response":
            _ = try await AuthSession.renewCredentials(boundCredentials())
            show("Refresh response deliberately lost")
        case "revoke":
            try await AuthSession.revokeCredentials(boundCredentials(), store: KeychainStorage())
            show("Remote revocation confirmed")
        case "reject-revoked":
            try await checkRevocation()
        case "refresh":
            try await KeychainStorage().update { vault in
                guard let account = vault.activeAccount, vault.current != nil else { throw ClientError.signedOut }
                vault.sessions[account]?.expiresAt = .distantPast
            }
            try await showRestoredSession()
        case "restore":
            try await showRestoredSession()
        default:
            throw ClientError.invalid("Unknown qualification phase.")
        }
    }

    private func prepareRequest(_ environment: [String: String]) async throws {
        try await KeychainStorage().remove()
        guard let path = environment["NEPHOS_QR_IMAGE"] else { throw QREnrollmentError.invalidQR }
        let raw = try QRImageDecoder.payload(Data(contentsOf: URL(fileURLWithPath: path)))
        let qr = try EnrollmentQR.parse(raw)
        let connection = try await QREnrollmentClient.connection(for: qr)
        _ = try await Task.detached { try Keychain.prepare(qr: qr, connection: connection) }.value
    }

    private func boundCredentials() async throws -> Credentials {
        guard let saved = try await KeychainStorage().vault().current, saved.dpopKeyThumbprint != nil else {
            throw ClientError.invalid("A bound session is required.")
        }
        return saved
    }

    private func checkRevocation() async throws {
        let model = SignInModel()
        await model.restore()
        guard model.screen == .welcome, try await KeychainStorage().vault().current == nil else {
            throw ClientError.invalid("Revocation did not invalidate the saved session.")
        }
        show("Revoked session rejected")
    }

    private func showRestoredSession() async throws {
        let model = SignInModel()
        await model.restore()
        guard model.screen == .signedIn, model.message.isEmpty else {
            throw ClientError.invalid("Session restoration failed.")
        }
        guard try await KeychainStorage().vault().current?.dpopKeyThumbprint != nil else {
            throw ClientError.invalid("Restoration silently lost device binding.")
        }
        window?.rootViewController = UIHostingController(rootView: AppRootView(model: model))
    }

    private func errorCode(_ error: Error) -> String {
        if let error = error as? QREnrollmentError { return error.rawValue }
        if let error = error as? URLError { return "url:\(error.code.rawValue)" }
        if case ClientError.http(let status, _) = error { return "http:\(status)" }
        if case ClientError.invalid(let reason) = error {
            return [
                "Only signed RS256 identity tokens are supported.": "jwt-algorithm",
                "Identity token signature is invalid.": "jwt-signature",
                "Access token identity or lifetime validation failed.": "access-claims",
                "Refresh-token identity or device binding failed. Your session has been kept.": "refresh-claims",
                "Identity token nonce validation failed.": "id-nonce",
            ][reason] ?? "unexpected"
        }
        return "unexpected"
    }

    private func show(_ text: String) {
        window?.rootViewController = UIHostingController(rootView: Text(text))
    }
}
