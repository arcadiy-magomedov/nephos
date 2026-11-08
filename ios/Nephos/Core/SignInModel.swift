import Foundation
import Observation

@MainActor
@Observable
final class SignInModel {
    enum Screen: Equatable {
        case restoring, welcome, scanner, connecting, signedIn, recovery, qrError
    }

    private(set) var screen: Screen = .restoring
    private(set) var message = ""
    private(set) var serverName = ""
    private(set) var signingOut = false
    @ObservationIgnored private let store: any SessionStorage
    @ObservationIgnored private let connect: (EnrollmentQR) async throws -> Connection
    @ObservationIgnored private let exchange: (PendingEnrollment) async throws -> Credentials
    @ObservationIgnored private let renew: (@MainActor (Credentials) async throws -> Credentials)?
    @ObservationIgnored private let validate: @MainActor (AuthSession) async throws -> Void
    @ObservationIgnored private var auth: AuthSession?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(
        store: any SessionStorage = KeychainStorage(),
        connect: @escaping (EnrollmentQR) async throws -> Connection = QREnrollmentClient.connection,
        exchange: @escaping (PendingEnrollment) async throws -> Credentials = QREnrollmentClient.exchange,
        renew: (@MainActor (Credentials) async throws -> Credentials)? = nil,
        validate: @escaping @MainActor (AuthSession) async throws -> Void = SignInModel.validateSession
    ) {
        self.store = store
        self.connect = connect
        self.exchange = exchange
        self.renew = renew
        self.validate = validate
    }

    func restore() async {
        await run {
            self.screen = .restoring
            let vault = try await self.store.vault()
            try Task.checkCancellation()
            if let saved = vault.current {
                try await self.establish(saved)
            } else if let pending = vault.pending {
                guard pending.installationID == vault.installationID else { throw QREnrollmentError.invalidProof }
                let connection = try await self.connect(pending.qr)
                try Task.checkCancellation()
                guard connection.hasSameIdentity(as: pending.connection) else {
                    throw ClientError.invalid("The saved server identity changed. Contact your administrator.")
                }
                try await self.finish(pending)
            } else {
                self.screen = .welcome
            }
        }
    }

    func scan() {
        guard operation == nil else { return }
        message = ""
        screen = .scanner
    }

    func cancelScan() {
        guard screen == .scanner else { return }
        screen = .welcome
    }

    func scannerFailed(_ error: Error) {
        guard screen == .scanner else { return }
        message = error.localizedDescription
        screen = .qrError
    }

    func importImage(_ data: Data) async {
        await run {
            self.screen = .connecting
            let payload = try await Task.detached { try QRImageDecoder.payload(data) }.value
            try Task.checkCancellation()
            try await self.enroll(payload)
        }
    }

    func accept(_ payload: String) async {
        await run {
            self.screen = .connecting
            try await self.enroll(payload)
        }
    }

    func imageFailed(_ error: Error) {
        guard operation == nil else { return }
        message = error.localizedDescription
        screen = .qrError
    }

    func signOut(remotely: Bool = false) async {
        guard !signingOut else { return }
        signingOut = true
        defer { signingOut = false }
        generation = UUID()
        operation?.cancel()
        operation = nil
        auth?.invalidate()
        auth = nil
        do {
            if remotely {
                guard let saved = try await store.vault().current else {
                    throw ClientError.invalid(
                        "Remote sign-out was not confirmed. Finish restoring your session or choose device-only sign-out."
                    )
                }
                try await AuthSession.revokeCredentials(saved, store: store)
            }
            try await store.remove()
            serverName = ""
            message = remotely ? "" : "Signed out on this device. The server session was not revoked."
            screen = .welcome
        } catch {
            screen = .recovery
            message = error.localizedDescription
        }
    }

    private func enroll(_ payload: String) async throws {
        let qr = try EnrollmentQR.parse(payload)
        let connection = try await connect(qr)
        try Task.checkCancellation()
        let vault = try await store.update { vault in
            if let saved = vault.pending, saved.qr == qr, saved.connection.hasSameIdentity(as: connection) {
                guard saved.installationID == vault.installationID else { throw QREnrollmentError.invalidProof }
            } else {
                let created = try PendingEnrollment(
                    qr: qr, connection: connection, installationID: vault.installationID)
                vault.pending = created
            }
        }
        try Task.checkCancellation()
        guard let pending = vault.pending else { throw QREnrollmentError.invalidProof }
        try await finish(pending)
    }

    private func finish(_ pending: PendingEnrollment) async throws {
        screen = .connecting
        let credentials = try await exchange(pending)
        try Task.checkCancellation()
        try await store.update { try $0.commit(credentials, requestID: pending.requestID) }
        try Task.checkCancellation()
        try await establish(credentials)
    }

    private func establish(_ credentials: Credentials) async throws {
        let session = AuthSession(credentials: credentials, store: store, renew: renew)
        auth?.invalidate()
        auth = session
        serverName = credentials.connection.baseURL.host ?? credentials.connection.baseURL.absoluteString
        try await validate(session)
        try Task.checkCancellation()
        screen = .signedIn
        message = ""
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) async {
        guard !signingOut else { return }
        if let operation {
            await operation.value
            return
        }
        let version = generation
        let task = Task { @MainActor in
            do { try await work() } catch {
                guard self.generation == version else { return }
                await self.handle(error, version: version)
            }
        }
        operation = task
        await task.value
        if generation == version { operation = nil }
    }

    private func handle(_ error: Error, version: UUID) async {
        if error is ClientError, case ClientError.signedOut = error {
            do {
                try await store.remove()
                guard generation == version else { return }
                auth?.invalidate()
                auth = nil
                screen = .welcome
                message = error.localizedDescription
            } catch {
                guard generation == version else { return }
                screen = .recovery
                message = error.localizedDescription
            }
            return
        }
        do {
            if let qrError = error as? QREnrollmentError, qrError.invalidatesEnrollment {
                try await store.update { $0.pending = nil }
            }
            let vault = try await store.vault()
            guard generation == version else { return }
            screen = vault.current != nil || vault.pending != nil ? .recovery : .qrError
            message =
                AuthSession.isCancelled(error) ? "Connection interrupted. Please retry." : error.localizedDescription
        } catch {
            guard generation == version else { return }
            screen = .recovery
            message = error.localizedDescription
        }
    }

    static func validateSession(_ session: AuthSession) async throws {
        guard let saved = session.credentials else { throw ClientError.signedOut }
        let connection = saved.connection
        _ = try URLPolicy.validate(connection.baseURL.absoluteString)
        let config = try await HTTP.json(
            ServerConfig.self, HTTP.request(connection.baseURL.appendingPathComponent("v1/config")))
        let advertised = Connection(baseURL: connection.baseURL, config: config, allowDevelopmentHTTP: false)
        guard connection.hasSameIdentity(as: advertised) else {
            throw ClientError.invalid("The saved server identity changed. Contact your administrator.")
        }
        let api = API(connection: connection, auth: session)
        defer { api.invalidate() }
        _ = try await api.data(api.request("v1/libraries", query: [URLQueryItem(name: "limit", value: "1")]))
    }
}
