import AVFoundation
import SwiftUI
import UIKit

struct QRScanner: UIViewControllerRepresentable {
    let result: (Result<String, Error>) -> Void
    func makeUIViewController(context: Context) -> QRScannerController { QRScannerController(result: result) }
    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: QRScannerController, coordinator: ()) {
        uiViewController.stop()
    }
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.nephos.qr-camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var finished = false
    private var observation: NSObjectProtocol?
    private let result: (Result<String, Error>) -> Void

    init(result: @escaping (Result<String, Error>) -> Void) {
        self.result = result
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: capture)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
        observation = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: capture, queue: .main
        ) { [weak self] _ in
            self?.deliver(
                .failure(
                    ClientError.invalid("Camera capture stopped. Retry scanning or import the QR image from Photos.")))
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configure() } else { self?.denied() }
                }
            }
        default: denied()
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }
    private func denied() {
        deliver(
            .failure(
                ClientError.invalid(
                    "Camera access is off. Import the QR image from Photos or enable Camera in Settings.")))
    }
    private func configure() {
        guard !finished else { return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard let camera = AVCaptureDevice.default(for: .video) else {
                    throw ClientError.invalid("No camera is available. Import the QR image from Photos.")
                }
                let input = try AVCaptureDeviceInput(device: camera)
                let output = AVCaptureMetadataOutput()
                self.capture.beginConfiguration()
                guard self.capture.canAddInput(input), self.capture.canAddOutput(output) else {
                    self.capture.commitConfiguration()
                    throw ClientError.invalid("The camera could not start. Import the QR image from Photos.")
                }
                self.capture.addInput(input)
                self.capture.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                guard output.availableMetadataObjectTypes.contains(.qr) else {
                    self.capture.commitConfiguration()
                    throw ClientError.invalid("QR capture is unavailable. Import the QR image from Photos.")
                }
                output.metadataObjectTypes = [.qr]
                self.capture.commitConfiguration()
                self.capture.startRunning()
            } catch {
                DispatchQueue.main.async { self.deliver(.failure(error)) }
            }
        }
    }
    func metadataOutput(
        _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let codes = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        guard codes.count == 1, let code = codes.first else { return }
        deliver(.success(code))
    }
    private func deliver(_ value: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        stop()
        result(value)
    }
    func stop() {
        finished = true
        queue.async { [capture] in if capture.isRunning { capture.stopRunning() } }
    }
    deinit {
        if let observation { NotificationCenter.default.removeObserver(observation) }
    }
}
