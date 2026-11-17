import Photos
import SwiftUI

struct MediaSettingsView: View {
    let uploads: UploadModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                ForEach(UploadPolicy.allCases, id: \.self) { policy in
                    Button {
                        Task { await uploads.setPolicy(policy) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: uploads.snapshot.policy == policy ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(MediaStyle.accent)
                            Text(policy.title).foregroundStyle(MediaStyle.text)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(uploads.snapshot.policy == policy ? .isSelected : [])
                    .accessibilityIdentifier("settings.upload.\(policy.rawValue)")
                }
            } header: {
                Text("Automatic upload")
            } footer: {
                Text(
                    "Back up permitted photos and videos to your Nephos server. Transfers can continue when you leave the app. iOS chooses when background checks run; reopening Nephos checks for new media."
                )
            }
            Section("Upload library") {
                if uploads.loadingLibraries { ProgressView("Loading libraries") }
                ForEach(uploads.libraries) { library in
                    Button {
                        Task { await uploads.select(library) }
                    } label: {
                        HStack {
                            Text(library.name).foregroundStyle(MediaStyle.text)
                            Spacer()
                            if uploads.destination?.libraryID == library.id { Image(systemName: "checkmark") }
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityAddTraits(uploads.destination?.libraryID == library.id ? .isSelected : [])
                }
                if let destination = uploads.destination, uploads.libraries.isEmpty {
                    Text(destination.libraryName)
                }
                if let message = uploads.message {
                    Text(message).font(.footnote).foregroundStyle(MediaStyle.secondary)
                    Button("Retry") { Task { await uploads.loadLibraries() } }.frame(minHeight: 44)
                }
            }
            Section {
                NavigationLink("Uploads", value: MediaRoute.uploads)
                    .accessibilityIdentifier("settings.uploads")
                Button("Manage Photos access", systemImage: "photo.badge.plus") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .frame(minHeight: 44)
            } footer: {
                Text(
                    "Uploads includes completed files, failures with error details, and scheduled work. Removing an item from Photos does not delete its server backup."
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(MediaStyle.background).foregroundStyle(MediaStyle.text).tint(MediaStyle.accent)
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await uploads.loadLibraries() }
        .accessibilityIdentifier("settings.screen")
    }
}
