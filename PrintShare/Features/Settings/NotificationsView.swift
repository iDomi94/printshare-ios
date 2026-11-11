import SwiftUI
import UIKit
import UserNotifications

/// Push notifications and Live Activities (server 0.51.0): on/off for this phone, which events, a test.
struct NotificationsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var device: PushDevice?
    @State private var loaded = false
    @State private var busy = false
    @State private var error = ""
    @State private var info = ""
    @State private var denied = false
    @State private var serverOld = false

    private var push: PushNotifications { PushNotifications.shared }

    var body: some View {
        let t = app.l10n
        PSScreen {
            Text(t(.notifyIntro)).font(.subheadline).foregroundStyle(Theme.sub).padding(.bottom, 16)
            if serverOld { PSBanner(kind: .warn, text: t(.errServerOld)) }
            if denied {
                PSBanner(kind: .warn, text: t(.notifyDenied))
                PSButton(title: t(.openSettings), kind: .secondary, icon: "gear") {
                    if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) }
                }
                .padding(.bottom, 12)
            }
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            if !info.isEmpty { PSBanner(kind: .ok, text: info) }
            if !loaded { ProgressView().frame(maxWidth: .infinity) }

            if loaded && !serverOld {
                PSSection(footer: app.isCloud ? t(.notifyPhoneOnly) : nil) {
                    toggle(t(.notifyEnable), icon: "bell.badge", on: device != nil) { on in
                        Task { on ? await enable() : await disable() }
                    }
                }
                if let device {
                    PSSection(footer: t(.notifyDecisionsSub)) {
                        toggle(t(.notifyDone), icon: "checkmark.circle", on: device.prefs.done) { v in set { $0.done = v } }
                        PSDivider()
                        toggle(t(.notifyProblems), icon: "exclamationmark.triangle", on: device.prefs.problems) { v in set { $0.problems = v } }
                        PSDivider()
                        toggle(t(.notifyDecisions), icon: "questionmark.circle", on: device.prefs.decisions) { v in set { $0.decisions = v } }
                        PSDivider()
                        toggle(t(.notifyInfo), icon: "printer", on: device.prefs.info) { v in set { $0.info = v } }
                    }
                    PSSection(footer: t(.notifyActivitiesSub)) {
                        toggle(t(.notifyActivities), icon: "platter.filled.bottom.iphone", on: device.prefs.activities) { v in
                            set { $0.activities = v }
                        }
                    }
                    PSButton(title: t(.notifyTest), kind: .secondary, icon: "paperplane", loading: busy) {
                        Task { await test() }
                    }
                }
            }
        }
        .navigationTitle(t(.notifyTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: app.server) { await load() }
    }

    private func toggle(_ label: String, icon: String, on: Bool, _ change: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { change($0) })) {
            Label {
                Text(label).font(.body).foregroundStyle(Theme.text)
            } icon: {
                Image(systemName: icon).foregroundStyle(Theme.accent)
            }
        }
        .tint(Theme.accent)
        .disabled(busy)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func message(_ e: Error) -> String {
        let t = app.l10n
        guard let p = e as? PushError else { return e.localizedDescription }
        switch p {
        case .denied: denied = true; return ""
        case .noToken: return t(.notifyNoToken)
        case .relayOff: return t(.notifyRelayOff)
        case .notConnected: return t(.notConnected)
        }
    }

    private func load() async {
        loaded = false
        error = ""
        serverOld = false
        do {
            device = try await push.device()
            if device == nil, push.record() == nil, let api = app.api { _ = try await api.pushInfo() }
        } catch let e as APIError where e.status == 404 {
            serverOld = true
        } catch {
            self.error = message(error)
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        denied = settings.authorizationStatus == .denied
        loaded = true
    }

    private func enable() async {
        busy = true
        error = ""
        info = ""
        defer { busy = false }
        do {
            device = try await push.enable()
            denied = false
            Haptics.success()
        } catch let e as APIError where e.status == 404 {
            serverOld = true
        } catch {
            self.error = message(error)
        }
    }

    private func disable() async {
        busy = true
        defer { busy = false }
        await push.disable()
        device = nil
        info = ""
    }

    private func set(_ change: (inout PushPrefs) -> Void) {
        guard var prefs = device?.prefs else { return }
        change(&prefs)
        Haptics.tap()
        Task {
            busy = true
            defer { busy = false }
            do { device = try await push.setPrefs(prefs) } catch { self.error = message(error) }
        }
    }

    private func test() async {
        busy = true
        error = ""
        info = ""
        defer { busy = false }
        do {
            try await push.test()
            info = app.l10n(.notifyTestSent)
        } catch {
            self.error = message(error)
        }
    }
}
