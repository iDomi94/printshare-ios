import AVFoundation
import SwiftUI
import UIKit

/// Owns the capture session; started and stopped on its own queue (AVFoundation asks for that).
final class ScannerSession: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "printshare.scanner")
    private let onCode: @MainActor @Sendable (String) -> Void
    private var configured = false

    init(onCode: @escaping @MainActor @Sendable (String) -> Void) {
        self.onCode = onCode
    }

    func start() {
        queue.async { [self] in
            if !configured {
                configured = true
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) else { return }
                session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else { return }
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        let handler = onCode
        Task { @MainActor in handler(code) }
    }
}

final class ScannerPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }  // swiftlint:disable:this force_cast
}

/// Camera preview that reports QR codes.
struct QRScannerView: UIViewRepresentable {
    var onCode: @MainActor @Sendable (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> ScannerPreviewView {
        let view = ScannerPreviewView()
        view.previewLayer.session = context.coordinator.scanner.session
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.scanner.start()
        return view
    }

    func updateUIView(_ uiView: ScannerPreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: ScannerPreviewView, coordinator: Coordinator) {
        coordinator.scanner.stop()
    }

    final class Coordinator {
        let scanner: ScannerSession
        init(onCode: @escaping @MainActor @Sendable (String) -> Void) {
            scanner = ScannerSession(onCode: onCode)
        }
    }
}
