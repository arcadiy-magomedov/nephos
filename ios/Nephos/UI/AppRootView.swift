import SwiftUI

struct AppRootView: View {
    @Bindable var model: SignInModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmSignOut = false
    private let uploads = UploadModel.shared

    var body: some View {
        Group {
            if model.screen == .signedIn {
                NavigationStack {
                    LocalGalleryView(session: model) { confirmSignOut = true }
                        .toolbar(.hidden, for: .navigationBar)
                        .navigationDestination(for: MediaRoute.self) { route in
                            switch route {
                            case .settings: MediaSettingsView(uploads: uploads)
                            case .uploads: UploadsView(uploads: uploads)
                            }
                        }
                }
            } else if model.screen == .restoring {
                MediaStyle.background.ignoresSafeArea()
            } else {
                SignInView(model: model)
            }
        }
        .task {
            uploads.onSessionRevoked = { [model] in await model.handleExternalSignOut() }
            if model.screen == .restoring { await model.restore() }
            if model.screen == .signedIn, scenePhase == .active { uploads.foreground() }
        }
        .onChange(of: model.screen) { _, screen in
            if screen == .signedIn, scenePhase == .active {
                uploads.foreground()
            } else if screen == .welcome {
                Task { await uploads.stop() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                model.cancelScan()
                uploads.background()
            }
            if phase == .active, model.screen == .signedIn || model.screen == .recovery {
                uploads.foreground()
                Task { await model.restore() }
            }
        }
        .confirmationDialog("Sign out of Nephos?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task {
                    await uploads.stop()
                    await model.signOut(remotely: true)
                    if model.screen == .signedIn { uploads.foreground() }
                }
            }
            Button("Sign out on this device only", role: .destructive) {
                Task {
                    await uploads.stop()
                    await model.signOut()
                    if model.screen == .signedIn { uploads.foreground() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                """
                You will need a new QR code to sign in again. Device-only sign-out removes saved credentials \
                but does not revoke the server session.
                """
            )
        }
    }
}
