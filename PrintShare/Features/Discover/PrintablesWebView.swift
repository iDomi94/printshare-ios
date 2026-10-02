import SwiftUI
import WebKit

/// printables.com inside the app (test build): the user signs in on the site itself, so likes and private collections
/// work without the app or the server ever seeing the password or the cookies. The web view uses the default
/// (persistent) website data store, so the login survives app restarts. On a model page a native button opens the
/// model in the normal flow; the server then downloads it without a login, as for a search hit.
struct PrintablesWebView: View {
    @Environment(AppModel.self) private var app
    @State private var web = PrintablesWeb()
    @State private var confirmLogout = false
    @AppStorage("printablesWebHintSeen") private var hintSeen = false

    var body: some View {
        let t = app.l10n
        VStack(spacing: 0) {
            if !hintSeen {
                HStack(alignment: .top, spacing: 0) {
                    PSBanner(kind: .info, text: t(.printablesWebHint)).padding(.bottom, -14)
                    Button { hintSeen = true } label: {
                        Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(Theme.sub).padding(10)
                    }
                    .accessibilityLabel(t(.close))
                }
                .padding(.horizontal, Theme.space).padding(.vertical, 8)
            }
            ZStack(alignment: .top) {
                WebViewHost(view: web.view)
                if web.loading { ProgressView(value: web.progress).progressViewStyle(.linear).tint(Theme.accent) }
            }
            bottomBar(t)
        }
        .background(Theme.bg)
        .navigationTitle("Printables")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { web.view.reload() } label: { Label(t(.webReload), systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { confirmLogout = true } label: {
                        Label(t(.printablesLogout), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel(t(.more))
            }
        }
        .confirmationDialog(t(.printablesLogoutConfirm), isPresented: $confirmLogout, titleVisibility: .visible) {
            Button(t(.printablesLogout), role: .destructive) { Task { await web.signOut() } }
            Button(t(.cancelBtn), role: .cancel) {}
        }
        .onChange(of: web.downloadRequests) { _, _ in openModel() }
        .onAppear { web.start() }
    }

    private func bottomBar(_ t: L10n) -> some View {
        VStack(spacing: 8) {
            if web.downloadBlocked && web.modelId == nil {
                PSBanner(kind: .info, text: t(.printablesDownloadHint)).padding(.bottom, -14)
            }
            HStack(spacing: 6) {
                navButton("chevron.backward", t(.webBack), enabled: web.canGoBack) { web.view.goBack() }
                navButton("chevron.forward", t(.webForward), enabled: web.canGoForward) { web.view.goForward() }
                PSButton(title: t(.printablesPrintThis), icon: "printer", disabled: web.modelId == nil) { openModel() }
            }
        }
        .padding(.horizontal, Theme.space).padding(.top, 8).padding(.bottom, 6)
        .background(Theme.bg)
    }

    private func navButton(_ icon: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3.weight(.semibold)).frame(width: 44, height: 52)
        }
        .disabled(!enabled)
        .foregroundStyle(enabled ? Theme.accent : Theme.sub.opacity(0.5))
        .accessibilityLabel(label)
    }

    private func openModel() {
        guard let id = web.modelId else { return }
        Haptics.tap()
        app.push(.model(source: "printables", id: id))
    }
}

/// The web view and what the screen shows about it.
@MainActor @Observable
final class PrintablesWeb: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let home = URL(string: "https://www.printables.com/")!

    let view: WKWebView
    var canGoBack = false
    var canGoForward = false
    var loading = false
    var progress = 0.0
    /// Printables model id of the page shown (also for in-page navigation of the single-page site).
    var modelId: String?
    /// The site tried to download a file; the file never goes to the phone, the model opens in our flow instead.
    var downloadRequests = 0
    var downloadBlocked = false

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var started = false

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // persistent: the Printables login stays
        config.allowsInlineMediaPlayback = true
        view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        // KVO fires on the main thread for WKWebView; the site changes its URL by pushState, which no delegate reports
        observations = [
            view.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            view.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            view.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            view.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            view.observe(\.estimatedProgress) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
        ]
    }

    func start() {
        guard !started else { return }
        started = true
        view.load(URLRequest(url: Self.home))
    }

    private func sync() {
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
        loading = view.isLoading
        progress = view.estimatedProgress
        let id = Format.printablesId(view.url?.absoluteString)
        if id != modelId { modelId = id; downloadBlocked = false }
    }

    /// Removes the cookies and site data of Printables and the Prusa Account from the app, then reloads.
    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let ours = records.filter { r in ["printables.com", "prusa3d.com"].contains { r.displayName.hasSuffix($0) } }
        await store.removeData(ofTypes: types, for: ours)
        view.load(URLRequest(url: Self.home))
    }

    private func blockDownload() {
        downloadBlocked = true
        downloadRequests += 1
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { blockDownload(); return .cancel }
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(), scheme != "https", scheme != "http",
           scheme != "about", scheme != "blob", scheme != "data" {
            // mailto:, tel:, app links: hand them to the system
            _ = await UIApplication.shared.open(url, options: [:])
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let attachment = ((navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().hasPrefix("attachment")
        if attachment || !navigationResponse.canShowMIMEType { blockDownload(); return .cancel }
        return .allow
    }

    // MARK: WKUIDelegate

    /// Links that open a new window (target=_blank) load in the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

private struct WebViewHost: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
