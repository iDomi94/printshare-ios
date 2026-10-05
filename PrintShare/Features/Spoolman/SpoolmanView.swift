import SwiftUI

/// Spoolman (spec MA-07): where the spools are - the user's own Spoolman (address kept on this phone) or, for cloud
/// accounts, the PocketPrint3D cloud (server 0.17.0) - and bookings waiting for a decision.
struct SpoolmanView: View {
    private enum Mode: Hashable { case cloud, own }

    @Environment(AppModel.self) private var app
    @State private var mode: Mode?
    @State private var url = ""
    @State private var saved: String?
    @State private var count: Int?
    @State private var test: (ok: Bool, text: String)?
    @State private var testing = false
    @State private var bookings: [Booking] = []

    private var cloudOn: Bool { saved == Spoolman.cloudSetting }

    var body: some View {
        let t = app.l10n
        Group {
            if let mode { content(t, mode) } else { Theme.bg }
        }
        .navigationTitle(t(.spoolman))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
    }

    private func content(_ t: L10n, _ current: Mode) -> some View {
        let open = bookings.filter { $0.ask != nil }
        let waiting = bookings.filter { $0.ask == nil }
        return PSScreen {
            if app.isCloud {
                PSSection(title: t(.spoolsWhere), footer: current == .cloud ? t(.spoolsCloudHint) : nil) {
                    PSSegmented(values: [Mode.cloud, .own], selection: Binding(get: { current }, set: { mode = $0; test = nil }),
                                label: { t($0 == .cloud ? .spoolsInCloud : .spoolsOwnServer) })
                        .padding(12)
                    if current == .cloud && cloudOn {
                        PSDivider()
                        PSRow(icon: "circle.circle", label: t(.spoolsManage),
                              value: count.map { t(.spoolsCount, ["n": String($0)]) }) { app.push(.spools) }
                        PSDivider()
                        PSRow(icon: "xmark.circle", label: t(.spoolmanRemove), danger: true) { remove() }
                    }
                }
            }

            if current == .own {
                PSSection(title: t(.spoolmanAddress), footer: t(.spoolmanHint)) {
                    TextField("192.168.1.20:7912", text: Binding(get: { url }, set: { url = $0; test = nil }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .padding(.horizontal, Theme.space).padding(.vertical, 14)
                        .accessibilityLabel(t(.spoolmanAddress))
                    PSDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        PSButton(title: t(.testConnection), kind: .secondary, icon: "wifi", loading: testing,
                                 disabled: url.trimmingCharacters(in: .whitespaces).isEmpty) {
                            Task { _ = await check(url) }
                        }
                        if let test {
                            Text(test.text).font(.subheadline).foregroundStyle(test.ok ? Theme.ok : Theme.danger)
                        }
                    }
                    .padding(Theme.space)
                    if saved != nil && !cloudOn {
                        PSDivider()
                        PSRow(icon: "trash", label: t(.spoolmanRemove), danger: true) { remove() }
                    }
                }
            }

            if !open.isEmpty || !waiting.isEmpty {
                Text(t(.bookingsOpen)).textCase(.uppercase).font(.footnote).foregroundStyle(Theme.sub)
                    .padding(.leading, Theme.space).padding(.bottom, 6)
            }
            ForEach(open) { BookingCard(booking: $0) { reload() } }
            if !waiting.isEmpty {
                PSSection {
                    ForEach(Array(waiting.enumerated()), id: \.element.id) { i, b in
                        if i > 0 { PSDivider() }
                        PSRow(icon: "clock", label: b.file, value: "\(BookingCard.grams(b.grams)) g",
                              sub: "\(b.printerName) · \(t(.bookingWaits))")
                    }
                }
            }
            if saved == nil && !bookings.isEmpty { PSBanner(kind: .warn, text: t(.spoolmanOff)) }
        } footer: {
            if current == .cloud {
                if !cloudOn {
                    PSButton(title: t(.spoolsUseCloud), icon: "icloud") { Task { await save(Spoolman.cloudSetting) } }
                }
            } else {
                let v = url.trimmingCharacters(in: .whitespacesAndNewlines)
                PSButton(title: t(.save), icon: "checkmark", loading: testing, disabled: v.isEmpty || v == saved) {
                    Task { await save(url) }
                }
            }
        }
    }

    private func reload() {
        let s = app.spoolmanSetting()
        saved = s
        if mode == nil { mode = s != nil && s != Spoolman.cloudSetting ? .own : app.isCloud ? .cloud : .own }
        if let s, s != Spoolman.cloudSetting, url.isEmpty { url = s }
        bookings = app.bookings()
        Task { bookings = await app.loadBookings() }
        if s == Spoolman.cloudSetting, let sm = app.openSpoolman(Spoolman.cloudSetting) {
            Task { count = (try? await sm.spools())?.count }
        }
    }

    private func check(_ address: String) async -> Bool {
        let t = app.l10n
        guard let sm = app.openSpoolman(address) else { return false }
        testing = true
        test = nil
        defer { testing = false }
        do {
            let info = try await sm.info()
            let spools = try await sm.spools()
            test = (true, t(.spoolmanOk, ["version": info.version, "n": String(spools.count)]))
            return true
        } catch {
            test = (false, t(.spoolmanUnreachable, ["error": error.localizedDescription]))
            return false
        }
    }

    private func save(_ value: String) async {
        if value != Spoolman.cloudSetting, !(await check(value)) { return }
        app.saveSpoolmanSetting(value)
        reload()
    }

    private func remove() {
        app.saveSpoolmanSetting(nil)
        saved = nil
        url = ""
        test = nil
        count = nil
    }
}
