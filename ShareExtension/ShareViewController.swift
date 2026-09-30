import UIKit
import UniformTypeIdentifiers

/// Share sheet target: hands the shared link, text or file to the app through the App Group and opens the app.
final class ShareViewController: UIViewController {
    private let label = UILabel()

    private var german: Bool { (Locale.preferredLanguages.first ?? "").lowercased().hasPrefix("de") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.text = german ? "In PocketPrint3D öffnen" : "Open in PocketPrint3D"
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
        Task { await handle() }
    }

    private func handle() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        var shared: SharedItem?
        for provider in providers {
            if let item = await extract(provider) { shared = item; break }
        }
        if let shared, (try? SharedInbox.write(shared)) != nil, let url = URL(string: "printshare://share") {
            open(url)
        }
        // if the app did not come up by itself it processes the inbox the next time it becomes active
        try? await Task.sleep(for: .milliseconds(1200))
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func extract(_ p: NSItemProvider) async -> SharedItem? {
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let id = p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                ? UTType.fileURL.identifier : UTType.url.identifier
            return await loadURL(p, id)
        }
        if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return await loadText(p)
        }
        if let type = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) {
            return await loadFile(p, type)
        }
        return nil
    }

    private func loadURL(_ p: NSItemProvider, _ type: String) async -> SharedItem? {
        await withCheckedContinuation { cont in
            p.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                var url = item as? URL
                if url == nil, let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                guard let url else { cont.resume(returning: nil); return }
                if !url.isFileURL {
                    cont.resume(returning: SharedItem(url: url.absoluteString))
                    return
                }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let name = url.lastPathComponent
                if let rel = try? SharedInbox.stage(fileAt: url, name: name) {
                    cont.resume(returning: SharedItem(file: rel, fileName: name))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func loadText(_ p: NSItemProvider) async -> SharedItem? {
        await withCheckedContinuation { cont in
            _ = p.loadObject(ofClass: String.self) { text, _ in
                cont.resume(returning: text.map { SharedItem(text: $0) })
            }
        }
    }

    private func loadFile(_ p: NSItemProvider, _ type: String) async -> SharedItem? {
        await withCheckedContinuation { cont in
            _ = p.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { cont.resume(returning: nil); return }
                // the file is deleted when this handler returns: copy it now
                let name = url.lastPathComponent
                if let rel = try? SharedInbox.stage(fileAt: url, name: name) {
                    cont.resume(returning: SharedItem(file: rel, fileName: name))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// `UIApplication.shared` is unavailable in extensions: walk the responder chain to the application instead
    /// (same trick as expo-share-intent; the selector form keeps working on iOS 18).
    private func open(_ url: URL) {
        typealias OpenFn = @convention(c) (AnyObject, Selector, URL, [UIApplication.OpenExternalURLOptionsKey: Any],
                                           ((Bool) -> Void)?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                let imp = current.method(for: selector)
                let call = unsafeBitCast(imp, to: OpenFn.self)
                call(current, selector, url, [:], nil)
                return
            }
            responder = current.next
        }
    }
}
