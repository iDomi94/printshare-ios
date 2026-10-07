import SwiftUI

struct JobsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var jobs: [JobSummary]?
    @State private var names: [String: String] = [:]
    @State private var error = ""

    var body: some View {
        let t = app.l10n
        PSScreen(refresh: { await load() }) {
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            if let jobs {
                if jobs.isEmpty {
                    PSEmpty(icon: "tray", title: t(.jobsEmpty), sub: t(.jobsEmptySub))
                } else {
                    VStack(spacing: 10) {
                        ForEach(jobs) { j in row(t, j) }
                    }
                }
            }
        }
        .navigationTitle(t(.tabJobs))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: scenePhase == .active) { await pollWhileVisible() }
    }

    private func row(_ t: L10n, _ j: JobSummary) -> some View {
        let printer = j.printer.map { names[$0] ?? $0 }
        // a running print shows how far it is (server 0.39.0), also one started on the printer itself
        let progress = j.state == .started ? j.progress.map { "\(Int($0.rounded())) %" } : nil
        let meta = [printer, progress, j.printTime.map { Format.printTime($0) }, j.filamentG.map { String(format: "%.1f g", $0) },
                    Format.ago(t, j.created)].compactMap { $0 }.joined(separator: " · ")
        let icon = j.state == .error ? "exclamationmark.circle" : j.isExternal ? "printer" : "cube"
        return Button { Haptics.tap(); app.push(.job(j.id)) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2).foregroundStyle(j.state == .error ? Theme.danger : Theme.accent)
                    .frame(width: 30).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Format.jobName(file: j.file, link: j.link)).font(.body.weight(.medium))
                        .foregroundStyle(Theme.text).lineLimit(1)
                    Text(meta).font(.footnote).foregroundStyle(Theme.sub).lineLimit(1)
                }
                Spacer(minLength: 8)
                PSBadge(text: t.jobState(j.state.rawValue), kind: JobBadge.kind(j.state))
            }
            .padding(14).frame(maxWidth: .infinity)
            .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Poll every 5 s while the screen is visible and the app is in the foreground.
    private func pollWhileVisible() async {
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func load() async {
        guard let api = app.api else { return }
        do {
            async let j = api.jobs()
            async let ps = api.printers()
            let (list, printers) = try await (j, ps)
            jobs = list
            names = Dictionary(printers.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}
