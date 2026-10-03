import SwiftUI

/// Onboarding: log in to the PocketPrint3D cloud by e-mail code (server 0.15.0), or pair an own server by QR code,
/// deep link or manual entry.
struct ConnectView: View {
    private enum Mode: Hashable { case cloud, own }

    let request: ConnectRequest

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var url: String
    @State private var remote: String
    @State private var token: String
    @State private var error = ""
    @State private var busy = false
    @State private var scanning = false
    @State private var autoStarted = false
    @State private var mode: Mode
    @State private var email: String
    @State private var code = ""
    @State private var sentTo: String?

    /// `current`: the server the app is connected to, so "change server" opens on the matching mode.
    init(request: ConnectRequest, current: Server? = nil) {
        self.request = request
        let own = request.server.flatMap { $0.isCloud ? nil : $0 } ?? current.flatMap { $0.isCloud ? nil : $0 }
        _url = State(initialValue: own?.url ?? "")
        _remote = State(initialValue: own?.remoteUrl ?? "")
        _token = State(initialValue: own?.token ?? "")
        _mode = State(initialValue: own != nil || request.own ? .own : .cloud)
        _email = State(initialValue: current?.isCloud == true ? current?.email ?? "" : "")
    }

    var body: some View {
        let t = app.l10n
        NavigationStack {
            PSScreen {
                PSSegmented(values: [Mode.cloud, Mode.own], selection: $mode) { $0 == .cloud ? t(.modeCloud) : t(.modeOwn) }
                    .padding(.bottom, 20)
                    .onChange(of: mode) { _, _ in error = "" }
                if !error.isEmpty { PSBanner(kind: .error, text: error) }
                if mode == .cloud { cloud(t) } else { own(t) }
            }
            .navigationTitle(t(.connectTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t(.close)) { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $scanning) { ScanView() }
            .task {
                // opened from a pairing link: connect right away
                if request.autoConnect, !autoStarted, !url.isEmpty {
                    autoStarted = true
                    await connect()
                }
            }
        }
    }

    @ViewBuilder
    private func cloud(_ t: L10n) -> some View {
        Text(t(.cloudIntro)).font(.body).foregroundStyle(Theme.sub).padding(.bottom, 20)
        if let sentTo {
            Text(t(.codeSent, ["email": sentTo])).font(.body).foregroundStyle(Theme.text).padding(.bottom, 16)
            PSSection(title: t(.code)) {
                TextField("123456", text: Binding(get: { code }, set: { code = String($0.filter(\.isNumber).prefix(6)) }))
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced)).kerning(8)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.space).padding(.vertical, 14)
                    .accessibilityLabel(t(.code))
            }
            PSButton(title: t(.login), icon: "person.crop.circle.badge.checkmark", loading: busy, disabled: code.count != 6) {
                Task { await login() }
            }
            HStack(spacing: 10) {
                PSButton(title: t(.otherEmail), kind: .plain) { self.sentTo = nil; error = "" }
                PSButton(title: t(.resendCode), kind: .plain, disabled: busy) { Task { await requestCode() } }
            }
            .padding(.top, 12)
        } else {
            PSSection(title: t(.email)) {
                TextField("name@example.com", text: $email)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                    .textContentType(.emailAddress).submitLabel(.send)
                    .onSubmit { Task { await requestCode() } }
                    .padding(.horizontal, Theme.space).padding(.vertical, 14)
                    .accessibilityLabel(t(.email))
            }
            PSButton(title: t(.sendCode), icon: "envelope", loading: busy, disabled: !email.contains("@")) {
                Task { await requestCode() }
            }
        }
        Text(t(.cloudPrivacy)).font(.footnote).foregroundStyle(Theme.sub).padding(.top, 20).padding(.horizontal, 4)
    }

    @ViewBuilder
    private func own(_ t: L10n) -> some View {
        Text(t(.connectSub)).font(.body).foregroundStyle(Theme.sub).padding(.bottom, 20)

        PSButton(title: t(.scanQr), icon: "qrcode") { scanning = true }
        Text(t(.scanHelp)).font(.footnote).foregroundStyle(Theme.sub).padding(.top, 12).padding(.horizontal, 4)
        PSCard(padding: 12) {
            Text("docker exec PrintShare printshare pair --url http://SERVER-IP:8484")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text).textSelection(.enabled)
        }
        .padding(.top, 6).padding(.bottom, 8)
        Text(t(.pairCmdHint)).font(.footnote).foregroundStyle(Theme.sub).padding(.horizontal, 4).padding(.bottom, 28)

        PSSection(title: t(.manual)) {
            field(t(.serverUrl), "http://192.168.1.10:8484", $url)
            PSDivider()
            field(t(.remoteUrl), "http://100.x.y.z:8484", $remote)
            PSDivider()
            SecureField(t(.token), text: $token)
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.go)
                .onSubmit { Task { await connect() } }
                .padding(.horizontal, Theme.space).padding(.vertical, 14)
                .accessibilityLabel(t(.token))
        }
        Text(t(.remoteHint)).font(.footnote).foregroundStyle(Theme.sub)
            .padding(.horizontal, 16).padding(.top, -12).padding(.bottom, 20)
        PSButton(title: busy ? t(.connecting) : t(.connect), icon: "link", loading: busy,
                 disabled: url.trimmingCharacters(in: .whitespaces).isEmpty) { Task { await connect() } }
    }

    private func field(_ label: String, _ example: String, _ text: Binding<String>) -> some View {
        TextField("\(label) – \(example)", text: text)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            .padding(.horizontal, Theme.space).padding(.vertical, 14)
            .accessibilityLabel(label)
    }

    private func requestCode() async {
        guard email.contains("@"), !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            let r = try await CloudAuth.requestCode(email: email, l10n: app.l10n)
            sentTo = r.email
            code = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func login() async {
        guard let sentTo, code.count == 6 else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            let r = try await CloudAuth.login(email: sentTo, code: code, l10n: app.l10n)
            app.setServer(Server(url: Cloud.url, token: r.token, cloud: true, email: r.user.email))
            app.connectRequest = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func connect() async {
        busy = true
        error = ""
        defer { busy = false }
        do {
            let checked = try await Pairing.check(Server(url: url, token: token, remoteUrl: remote), app.l10n)
            app.setServer(checked)
            app.connectRequest = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
