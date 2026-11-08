import SwiftUI

@main
struct NephosApp: App {
    @State private var model = SignInModel()

    var body: some Scene {
        WindowGroup { SignInView(model: model) }
    }
}
