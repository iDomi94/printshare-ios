import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var link = ""
    @State private var error = ""
    @State private var recent: [JobSummary] = []
    @State private var pickingFile = false

    var body: some View {
        let t = app.l10n
        Group {
            if app.server == nil {
                ScrollView {
                    PSEmpty(icon: "shippingbox", title: t(.notConnectedTitle), sub: t(.notConnectedSub)) {
                        PSButton(title: t(.connectNow), icon: "link") { app.showConnect() }
                    }
                }
                .background(Theme.bg)
            } else {
                connected(t)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func connected(_ t: L10n) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(t(.homeTitle)).font(.largeTitle.bold()).foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader).padding(.top, 12)
                Text(t(.homeSub)).font(.body).foregroundStyle(Theme.sub).padding(.top, 8).padding(.bottom, 22)

                if !error.isEmpty { PSBanner(kind: .warn, text: error) }
                PSCard(padding: 12) {
                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "link").foregroundStyle(Theme.sub).accessibilityHidden(true)
                            TextField(t(.linkPlaceholder), text: $link)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .keyboardType(.URL).submitLabel(.go)
                                .onSubmit { go(link) }
                                .onChange(of: link) { _, _ in error = "" }
                                .accessibilityLabel(t(.linkPlaceholder))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 14)
                        .background(Theme.input).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        HStack(spacing: 10) {
                            PSButton(title: t(.paste), kind: .secondary, icon: "doc.on.clipboard") { paste() }
                            PSButton(title: t(.next), icon: "arrow.right",
                                     disabled: link.trimmingCharacters(in: .whitespaces).isEmpty) { go(link) }
                        }
                    }
                }

                PSCard {
                    VStack(spacing: 0) {
                        PSRow(icon: "folder", label: t(.pickFile), sub: t(.pickFileSub)) { pickingFile = true }
                        PSDivider()
                        PSRow(icon: "magnifyingglass", label: t(.searchModels), sub: t(.searchModelsSub)) {
                            app.navigate(to: .discover)
                        }
                    }
                }
                .padding(.top, 16)

                if !recent.isEmpty { recentSection(t) }
            }
            .padding(Theme.space).padding(.bottom, 24)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg)
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { pick(url) }
        }
        .task { await loadRecent() }
    }

    private func recentSection(_ t: L10n) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t(.recent)).textCase(.uppercase).font(.footnote).foregroundStyle(Theme.sub)
                .padding(.leading, Theme.space).padding(.top, 26)
            PSCard {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { i, j in
                        if i > 0 { PSDivider() }
                        Button { Haptics.tap(); app.push(.job(j.id)) } label: { recentRow(t, j) }
                            .buttonStyle(RowPressStyle())
                    }
                }
            }
        }
    }

    private func recentRow(_ t: L10n, _ j: JobSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "cube.fill").foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40).background(Theme.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.jobName(file: j.file, link: j.link)).font(.body).foregroundStyle(Theme.text).lineLimit(1)
                Text([j.printTime.map { Format.printTime($0) }, Format.ago(t, j.created)].compactMap { $0 }
                        .joined(separator: " · "))
                    .font(.footnote).foregroundStyle(Theme.sub).lineLimit(1)
            }
            Spacer(minLength: 8)
            PSBadge(text: t.jobState(j.state.rawValue), kind: JobBadge.kind(j.state, home: true))
        }
        .padding(14).contentShape(Rectangle())
    }

    private func loadRecent() async {
        guard let api = app.api else { return }
        if let jobs = try? await api.jobs() { recent = Array(jobs.prefix(3)) }
    }

    private func go(_ text: String) {
        let found = Format.extractLink(text)
        if found.isEmpty { error = app.l10n(.needLink); return }
        error = ""
        link = ""
        app.openLink(found)
    }

    private func paste() {
        let found = Format.extractLink(UIPasteboard.general.string)
        if found.isEmpty { error = app.l10n(.clipboardEmpty) } else { go(found) }
    }

    /// The picker hands out a security-scoped URL: copy the file before the scope ends.
    private func pick(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = dir.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
            app.push(.prepare(PrepareArgs(fileURL: target, fileName: url.lastPathComponent)))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Badge colour per job state (jobs list and recent jobs).
enum JobBadge {
    static func kind(_ state: JobState, home: Bool = false) -> PSBadgeKind {
        switch state {
        case .error: return .error
        case .finished: return .ok
        case .cancelled: return .warn
        case .started: return .accent
        case .done: return home ? .neutral : .ok
        case .sliced: return .accent
        default: return .neutral
        }
    }
}
