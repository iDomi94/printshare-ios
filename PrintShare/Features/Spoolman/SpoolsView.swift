import SwiftUI

/// Cloud spools (server 0.17.0): the spools of a PocketPrint3D account for users without their own Spoolman.
struct SpoolsView: View {
    @Environment(AppModel.self) private var app
    @State private var spools: [Spool]?
    @State private var archived = false
    @State private var error = ""

    var body: some View {
        let t = app.l10n
        Group {
            if spools == nil && error.isEmpty {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
            } else {
                list(t)
            }
        }
        .navigationTitle(t(.spools))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { await load() } }
        .onChange(of: archived) { _, _ in Task { await load() } }
    }

    private func list(_ t: L10n) -> some View {
        PSScreen(refresh: { await load() }) {
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            if let spools, spools.isEmpty, !archived {
                PSEmpty(icon: "circle.circle", title: t(.spoolsEmpty), sub: t(.spoolsEmptySub))
            }
            if let spools, !spools.isEmpty {
                PSSection {
                    ForEach(Array(spools.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { PSDivider() }
                        PSRow(label: s.label, sub: Self.line(t, s), action: { app.push(.spool(id: String(s.id))) }, right: {
                            ColorDot(color: Color(hexString: s.color)).padding(.leading, 8)
                        })
                        .opacity(s.archived ? 0.5 : 1)
                    }
                }
            }
            PSSection {
                Toggle(isOn: $archived) {
                    Label(t(.spoolsArchived), systemImage: "archivebox").foregroundStyle(Theme.text)
                }
                .tint(Theme.accent)
                .padding(.horizontal, Theme.space).padding(.vertical, 10)
            }
        } footer: {
            PSButton(title: t(.spoolAdd), icon: "plus") { app.push(.spool(id: SpoolFormView.new)) }
        }
    }

    /// "PLA · 640 g left · Shelf"
    static func line(_ t: L10n, _ s: Spool) -> String {
        [s.material, s.remainingG.map { t(.spoolLeft, ["g": String(Int($0.rounded()))]) }, s.location]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func load() async {
        guard let sm = app.openSpoolman(Spoolman.cloudSetting) else { return }
        do {
            spools = try await sm.spools(archived: archived)
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}
