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
        window.rootViewController = UIHostingController(rootView: ProgressView("Restoring session"))
        window.makeKeyAndVisible()
        Task { @MainActor in
            do {
                if environment["NEPHOS_UI_SCREEN"] == "qr-native-checks" {
                    try await Task.detached { try QRNativeQualification.checkPersistence() }.value
                    show("QR native checks passed")
                    return
                }
                if environment["NEPHOS_UI_SCREEN"] == "qr-real-login" {
                    switch environment["NEPHOS_QR_PHASE"] {
                    case "prepare":
                        try await KeychainStorage().remove()
                        guard let path = environment["NEPHOS_QR_IMAGE"] else { throw QREnrollmentError.invalidQR }
                        let raw = try QRImageDecoder.payload(Data(contentsOf: URL(fileURLWithPath: path)))
                        let qr = try EnrollmentQR.parse(raw)
                        let connection = try await QREnrollmentClient.connection(for: qr)
                        _ = try await Task.detached { try Keychain.prepare(qr: qr, connection: connection) }.value
                        show("QR request persisted")
                        return
                    case "discard-response":
                        guard let pending = try await KeychainStorage().vault().pending else {
                            throw QREnrollmentError.invalidProof
                        }
                        _ = try await QREnrollmentClient.exchange(pending)
                        show("QR response deliberately lost")
                        return
                    case "discard-refresh-response":
                        guard let saved = try await KeychainStorage().vault().current,
                            saved.dpopKeyThumbprint != nil
                        else { throw ClientError.invalid("A bound session is required.") }
                        _ = try await AuthSession.renewCredentials(saved)
                        show("Refresh response deliberately lost")
                        return
                    case "revoke":
                        guard let saved = try await KeychainStorage().vault().current,
                            saved.dpopKeyThumbprint != nil
                        else { throw ClientError.invalid("A bound session is required.") }
                        try await AuthSession.revokeCredentials(saved, store: KeychainStorage())
                        show("Remote revocation confirmed")
                        return
                    case "reject-revoked":
                        let model = SignInModel()
                        await model.restore()
                        guard model.screen == .welcome, try await KeychainStorage().vault().current == nil else {
                            throw ClientError.invalid("Revocation did not invalidate the saved session.")
                        }
                        show("Revoked session rejected")
                        return
                    case "refresh":
                        try await KeychainStorage().update { vault in
                            guard let account = vault.activeAccount, vault.current != nil else {
                                throw ClientError.signedOut
                            }
                            vault.sessions[account]?.expiresAt = .distantPast
                        }
                    case "restore": break
                    default: throw ClientError.invalid("Unknown qualification phase.")
                    }
                    let model = SignInModel()
                    await model.restore()
                    guard model.screen == .signedIn else { throw ClientError.invalid("Session restoration failed.") }
                    guard try await KeychainStorage().vault().current?.dpopKeyThumbprint != nil else {
                        throw ClientError.invalid("Restoration silently lost device binding.")
                    }
                    window.rootViewController = UIHostingController(rootView: SignInView(model: model))
                    return
                }
                try await KeychainStorage().remove()
                let model = SignInModel()
                await model.restore()
                if environment["NEPHOS_UI_SCREEN"] == "invalid-qr" { await model.accept("not-a-nephos-code") }
                window.rootViewController = UIHostingController(rootView: SignInView(model: model))
            } catch {
                let code: String
                if let error = error as? QREnrollmentError {
                    code = error.rawValue
                } else if let error = error as? URLError {
                    code = "url:\(error.code.rawValue)"
                } else if case ClientError.http(let status, _) = error {
                    code = "http:\(status)"
                } else if case ClientError.invalid(let reason) = error {
                    switch reason {
                    case "Only signed RS256 identity tokens are supported.": code = "jwt-algorithm"
                    case "Identity token signature is invalid.": code = "jwt-signature"
                    case "Access token identity or lifetime validation failed.": code = "access-claims"
                    case "Refresh-token identity or device binding failed. Your session has been kept.":
                        code = "refresh-claims"
                    case "Identity token nonce validation failed.": code = "id-nonce"
                    default: code = "unexpected"
                    }
                } else {
                    code = "unexpected"
                }
                show("QR_ERROR=\(code)")
            }
        }
        return true
    }

    private func show(_ text: String) {
        window?.rootViewController = UIHostingController(rootView: Text(text))
    }
}
