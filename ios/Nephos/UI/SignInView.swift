import PhotosUI
import SwiftUI

struct SignInView: View {
    @Bindable var model: SignInModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: PhotosPickerItem?
    @State private var photosPresented = false
    @State private var confirmSignOut = false
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    if model.screen == .scanner {
                        HStack {
                            Button("Cancel") { model.cancelScan() }
                                .frame(minWidth: 64, minHeight: 44)
                            Spacer()
                            Text("Scan QR code").font(.headline).accessibilityAddTraits(.isHeader)
                            Spacer()
                            Color.clear.frame(width: 64, height: 44).accessibilityHidden(true)
                        }
                    }
                    Spacer(minLength: 24)
                    content
                    Spacer(minLength: 40)
                    actions
                }
                .padding(24)
                .frame(maxWidth: 440)
                .frame(minHeight: geometry.size.height, alignment: .center)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(SignInStyle.background)
        .foregroundStyle(SignInStyle.text)
        .tint(SignInStyle.action)
        .photosPicker(isPresented: $photosPresented, selection: $image, matching: .images)
        .task {
            if model.screen == .restoring { await model.restore() }
        }
        .task(id: image) {
            guard let image else { return }
            do {
                guard let data = try await image.loadTransferable(type: Data.self) else {
                    throw ClientError.invalid("This photo could not be opened. Choose another QR image.")
                }
                try Task.checkCancellation()
                await model.importImage(data)
            } catch {
                if !AuthSession.isCancelled(error) { model.imageFailed(error) }
            }
            self.image = nil
        }
        .onChange(of: model.screen) { _, _ in headingFocused = true }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.cancelScan() }
            if phase == .active, model.screen == .signedIn || model.screen == .recovery {
                Task { await model.restore() }
            }
        }
        .confirmationDialog("Sign out of Nephos?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await model.signOut(remotely: true) } }
            Button("Sign out on this device only", role: .destructive) { Task { await model.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "You will need a new QR code to sign in again. Device-only sign-out removes saved credentials but does not revoke the server session."
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.screen {
        case .welcome:
            VStack(spacing: 24) {
                Image(systemName: "qrcode")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(SignInStyle.action)
                    .frame(width: 96, height: 96)
                    .background(SignInStyle.surface, in: RoundedRectangle(cornerRadius: 28))
                    .accessibilityHidden(true)
                heading("Nephos")
                detail("Your photos. Your server.")
                if !model.message.isEmpty { detail(model.message) }
            }
        case .scanner:
            VStack(spacing: 24) {
                QRScanner { result in
                    guard model.screen == .scanner else { return }
                    switch result {
                    case .success(let value): Task { await model.accept(value) }
                    case .failure(let error): model.scannerFailed(error)
                    }
                }
                .frame(maxWidth: 320)
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(SignInStyle.action, lineWidth: 2)
                        .padding(36)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel("QR camera preview")
                detail("Point the camera at the code from your administrator.")
            }
        case .restoring, .connecting:
            VStack(spacing: 20) {
                ProgressView()
                    .accessibilityLabel(model.screen == .restoring ? "Restoring session" : "Signing in")
                heading(model.screen == .restoring ? "Restoring session" : "Connecting")
                detail(
                    model.screen == .restoring
                        ? "Checking your saved session."
                        : "Sign-in starts as soon as the code is read.")
            }
        case .signedIn:
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 48)).foregroundStyle(SignInStyle.action).accessibilityHidden(true)
                heading("You're signed in")
                detail(model.serverName)
                if !model.message.isEmpty { detail(model.message) }
            }
            .accessibilityIdentifier("signin.success")
        case .recovery:
            VStack(spacing: 20) {
                heading("Couldn't connect")
                detail("Your sign-in is saved. You don't need a new QR code to retry.")
                detail(model.message)
            }
            .accessibilityIdentifier("signin.recovery")
        case .qrError:
            VStack(spacing: 20) {
                heading("Couldn't sign in")
                detail(model.message)
            }
            .accessibilityIdentifier("onboarding.qrError")
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.screen {
        case .welcome, .qrError:
            VStack(spacing: 8) {
                Button(model.screen == .welcome ? "Scan QR code" : "Scan again") { model.scan() }
                    .buttonStyle(SignInButtonStyle())
                    .accessibilityIdentifier("onboarding.scanQR")
                photoPicker
            }
        case .scanner:
            photoPicker
        case .recovery:
            VStack(spacing: 8) {
                Button("Retry") { Task { await model.restore() } }
                    .buttonStyle(SignInButtonStyle())
                signOutButton
            }
        case .signedIn:
            signOutButton
        case .restoring, .connecting:
            EmptyView()
        }
    }

    private var photoPicker: some View {
        Button("Choose QR from Photos") {
            model.cancelScan()
            photosPresented = true
        }
        .buttonStyle(SignInButtonStyle(primary: false))
        .accessibilityIdentifier("onboarding.importQR")
    }

    private var signOutButton: some View {
        Button("Sign out") { confirmSignOut = true }
            .buttonStyle(SignInButtonStyle(primary: false))
            .disabled(model.signingOut)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.title.weight(.semibold))
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($headingFocused)
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.body).foregroundStyle(SignInStyle.secondary)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }
}
