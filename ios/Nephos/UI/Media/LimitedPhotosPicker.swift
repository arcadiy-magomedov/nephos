import Photos
import SwiftUI

struct LimitedPhotosPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.requested = isPresented
        controller.onFinish = {
            isPresented = false
            onFinish()
        }
        controller.presentIfNeeded()
    }

    final class Controller: UIViewController {
        var requested = false
        var onFinish: (() -> Void)?
        private var presentingPicker = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            presentIfNeeded()
        }

        func presentIfNeeded() {
            guard requested, !presentingPicker, viewIfLoaded?.window != nil else { return }
            presentingPicker = true
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self) { [weak self] _ in
                Task { @MainActor in
                    self?.presentingPicker = false
                    self?.requested = false
                    self?.onFinish?()
                }
            }
        }
    }
}
