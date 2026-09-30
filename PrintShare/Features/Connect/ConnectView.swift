import SwiftUI

/// Onboarding: pair with the PrintShare server by QR code, deep link or manual entry.
struct ConnectView: View {
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

    init(request: ConnectRequest) {
        self.request = request
        _url = State(initialValue: request.server?.url ?? "")
        _remote = State(initialValue: request.server?.remoteUrl ?? "")
        _token = State(initialValue: request.server?.token ?? "")
    }

    var body: some View {
        let t = app.l10n
        NavigationStack {
            PSScreen {
                Text(t(.connectSub)).font(.body).foregroundStyle(Theme.sub).padding(.bottom, 20)
                if !error.isEmpty { PSBanner(kind: .error, text: error) }

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

    private func field(_ label: String, _ example: String, _ text: Binding<String>) -> some View {
        TextField("\(label) – \(example)", text: text)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            .padding(.horizontal, Theme.space).padding(.vertical, 14)
            .accessibilityLabel(label)
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
