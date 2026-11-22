import SwiftUI

@main
struct NephosApp: App {
    @UIApplicationDelegateAdaptor(UploadAppDelegate.self) private var appDelegate
    @State private var model = SignInModel()

    var body: some Scene {
        WindowGroup { AppRootView(model: model) }
    }
}
