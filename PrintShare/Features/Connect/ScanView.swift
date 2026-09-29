import AVFoundation
import SwiftUI
import UIKit

/// Full-screen QR scanner for the pairing code.
struct ScanView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var message = ""
    @State private var busy = false
    @State private var handled = false

    var body: some View {
        let t = app.l10n
        Group {
            if status == .authorized { camera(t) } else { permission(t) }
        }
    }

    private func permission(_ t: L10n) -> some View {
        let denied = status == .denied || status == .restricted
        return PSEmpty(icon: "camera", title: t(.scanTitle), sub: denied ? t(.cameraDenied) : t(.cameraNeeded)) {
            if denied {
                PSButton(title: t(.openSettings)) {
                    if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) }
                }
            } else {
                PSButton(title: t(.allowCamera)) { Task { await requestAccess() } }
            }
            PSButton(title: t(.cancelBtn), kind: .plain) { dismiss() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
    }

    private func camera(_ t: L10n) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            QRScannerView { code in Task { await onScan(code) } }.ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 34)).foregroundStyle(.white)
                    }
                    .accessibilityLabel(t(.close)).padding(16)
                }
                Spacer()
                RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white, lineWidth: 3)
                    .frame(width: 240, height: 240).accessibilityHidden(true)
                Spacer()
                VStack(spacing: 8) {
                    if busy { ProgressView().tint(.white) }
                    Text(message.isEmpty ? t(.scanTitle) : message).font(.body).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
        }
    }

    private func requestAccess() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        status = AVCaptureDevice.authorizationStatus(for: .video)
    }

    private func onScan(_ code: String) async {
        if handled || busy { return }
        guard let server = Pairing.parse(code) else {
            message = app.l10n(.invalidQr)
            return
        }
        handled = true
        busy = true
        defer { busy = false }
        do {
            let checked = try await Pairing.check(server, app.l10n)
            Haptics.success()
            app.setServer(checked)
            app.connectRequest = nil
        } catch {
            message = error.localizedDescription
            handled = false
        }
    }
}
