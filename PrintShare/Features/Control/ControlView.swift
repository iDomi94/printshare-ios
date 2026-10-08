import Charts
import SwiftUI

/// Printer control (issue #5): temperatures with history, fans, light and print speed.
/// Anything that could spoil a running print needs an explicit confirmation (NF-05); nothing is sent twice
/// without the user tapping again.
struct ControlView: View {
    let printer: String
    let name: String

    /// One change sent to `POST /adjust`.
    struct Change: Equatable, Sendable {
        var kind: AdjustKind
        var id: String
        var value: AdjustValue
    }

    private struct Question: Identifiable {
        let id = UUID()
        var text: String
        var destructive: Bool
        /// Label of the confirming button (default: "Change").
        var confirm: String?
        var onConfirm: @MainActor () -> Void
    }

    private struct HeaterPick: Identifiable { var id: String }

    static let fanSteps = [0, 25, 50, 75, 100]
    /// Targets from here on are asked for once (spec: never surprise the user with a hot printer).
    static let high: [String: Double] = ["nozzle": 260, "bed": 100, "chamber": 50]
    struct Preset: Identifiable, Sendable {
        var key: L10nKey
        var nozzle: Double
        var bed: Double
        var icon: String?
        var id: String { key.rawValue }
    }

    static let presets = [
        Preset(key: .preheatPla, nozzle: 210, bed: 60), Preset(key: .preheatPetg, nozzle: 240, bed: 80),
        Preset(key: .coolDown, nozzle: 0, bed: 0, icon: "snowflake"),
    ]

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var caps: Controls?
    @State private var status: PrinterStatus?
    @State private var history: TempHistory?
    @State private var error = ""
    @State private var busy = ""
    @State private var picker: HeaterPick?
    @State private var question: Question?
    /// Home Assistant plug of the printer (issue #9), nil when the server has none.
    @State private var power: PowerInfo?
    /// Moving by hand (server 0.43.0), nil on older servers or printers without it.
    @State private var motion: Motion?

    private var printing: Bool { status?.kind.isBusy ?? false }

    var body: some View {
        let t = app.l10n
        Group {
            if caps == nil && error.isEmpty {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
            } else {
                content(t)
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadControls() }
        .task { await loadPower() }
        .task { await loadMotion() }
        .task(id: scenePhase == .active) { await pollStatus() }
        .task(id: scenePhase == .active) { await pollHistory() }
        .sheet(item: $picker) { heaterSheet(t, $0.id) }
        .alert(question?.text ?? "", isPresented: Binding(get: { question != nil }, set: { if !$0 { question = nil } }),
               presenting: question) { q in
            Button(t(.cancelBtn), role: .cancel) {}
            Button(q.confirm ?? t(.change), role: q.destructive ? .destructive : nil) { q.onConfirm() }
        }
    }

    private func content(_ t: L10n) -> some View {
        let heaters = shownHeaters
        return PSScreen {
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            if printing { PSBanner(kind: .warn, text: t(.printRunningHint)) }

            if !heaters.isEmpty {
                PSSection(title: t(.temperatures)) {
                    ForEach(Array(heaters.enumerated()), id: \.element) { i, h in
                        if i > 0 { PSDivider() }
                        heaterRow(t, h)
                    }
                    if canHeat("nozzle") && canHeat("bed") {
                        PSDivider()
                        presetButtons(t)
                    }
                }
                PSCard(padding: 12) { TempChart(series: history?.series ?? [:]) }
                    .padding(.bottom, 22)
            }

            if let motion {
                MotionPanel(printer: printer, caps: motion, printing: printing,
                            nozzle: status?.heaters["nozzle"]?.actual) {
                    request("heatForExtrude", [Change(kind: .heater, id: "nozzle", value: .number(220))])
                }
            }

            if let fans = caps?.fans, !fans.isEmpty {
                PSSection(title: t(.fans)) {
                    ForEach(Array(fans.enumerated()), id: \.element.id) { i, f in
                        if i > 0 { PSDivider() }
                        fanRow(t, f.id)
                    }
                }
            }

            if let lights = caps?.lights, !lights.isEmpty {
                PSSection(title: t(.lights)) {
                    ForEach(Array(lights.enumerated()), id: \.element.id) { i, l in
                        if i > 0 { PSDivider() }
                        PSRow(icon: "lightbulb", label: t.lightName(l.id), right: {
                            Toggle("", isOn: Binding(get: { status?.lights[l.id] ?? false }, set: { on in
                                request("light:\(l.id)", [Change(kind: .light, id: l.id, value: .flag(on))])
                            }))
                            .labelsHidden().tint(Theme.accent).disabled(busy == "light:\(l.id)")
                        })
                    }
                }
            }

            if let values = caps?.speedValues, !values.isEmpty {
                PSSection(title: t(.speedTitle)) {
                    stepButtons(values.map { v in
                        (label: caps?.speed?.modes?.isEmpty == false ? t.speedMode(v) : "\(v) %",
                         on: status?.speed == v, key: "speed:\(v)")
                    }) { i in
                        request("speed", [Change(kind: .speed, id: "speed", value: .number(Double(values[i])))])
                    }
                    .padding(12)
                }
            }

            if let power, power.available {
                PSSection(title: t(.powerTitle), footer: printing ? t(.powerOffBusy) : nil) {
                    PSRow(icon: "power", label: t(.powerOff), value: power.state.map { t.powerState($0) },
                          danger: !printing, chevron: false,
                          action: printing || busy == "power" ? nil : { askPowerOff(t) }) {
                        if busy == "power" { ProgressView().padding(.leading, 8) }
                    }
                    .opacity(printing ? 0.5 : 1)
                }
            }
        }
    }

    /// Switching the plug off always asks first; the server refuses it during a print anyway (409).
    private func askPowerOff(_ t: L10n) {
        question = Question(text: t(.powerOffQ, ["printer": name]), destructive: true, confirm: t(.powerOff)) {
            Task { await powerOff() }
        }
    }

    private func powerOff() async {
        guard let api = app.api else { return }
        busy = "power"
        do {
            try await api.setPower(printer: printer, on: false)
            power?.state = "off"
            error = ""
        } catch { self.error = error.localizedDescription }
        busy = ""
    }

    // MARK: rows

    /// Heaters the printer reports plus the ones it can set, nozzle / bed / chamber first.
    private var shownHeaters: [String] {
        var ids = Set(status?.heaters.keys.map { $0 } ?? [])
        for h in caps?.heaters ?? [] { ids.insert(h.id) }
        let order = ["nozzle", "bed", "chamber"]
        return ids.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? order.count, ib = order.firstIndex(of: b) ?? order.count
            return ia != ib ? ia < ib : a < b
        }
    }

    private func canHeat(_ id: String) -> Bool { caps?.heaters.contains { $0.id == id } ?? false }

    private func heaterRow(_ t: L10n, _ h: String) -> some View {
        let st = status?.heaters[h]
        var value = st?.actual.map { "\(Int($0.rounded())) °C" } ?? "–"
        if let target = st?.target, target > 0 { value += " → \(Int(target.rounded())) °C" }
        let icon = h == "nozzle" ? "flame" : h == "bed" ? "square" : "cube"
        var action: (() -> Void)?
        if canHeat(h) { action = { picker = HeaterPick(id: h) } }
        return PSRow(icon: icon, label: t.heaterName(h), value: value, sub: canHeat(h) ? nil : t(.sensorOnly),
                     action: action, right: { if busy == "heater:\(h)" { ProgressView().padding(.leading, 8) } })
    }

    private func presetButtons(_ t: L10n) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Self.presets.prefix(2)) { p in presetButton(t, p) }
            }
            ForEach(Self.presets.suffix(1)) { p in presetButton(t, p) }
        }
        .padding(12)
    }

    private func presetButton(_ t: L10n, _ p: Preset) -> some View {
        PSButton(title: t(p.key), kind: .secondary, icon: p.icon, loading: busy == p.key.rawValue) {
            request(p.key.rawValue, [Change(kind: .heater, id: "nozzle", value: .number(p.nozzle)),
                                     Change(kind: .heater, id: "bed", value: .number(p.bed))])
        }
    }

    private func fanRow(_ t: L10n, _ id: String) -> some View {
        let current = status?.fans[id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t.fanName(id)).font(.body).foregroundStyle(Theme.text)
                Spacer()
                Text(current.map { "\(Int($0.rounded())) %" } ?? "–").font(.subheadline).foregroundStyle(Theme.sub)
            }
            stepButtons(Self.fanSteps.map { v in
                (label: v == 0 ? t(.off) : String(v), on: current.map { abs($0 - Double(v)) < 5 } ?? false,
                 key: "fan:\(id)")
            }) { i in
                request("fan:\(id)", [Change(kind: .fan, id: id, value: .number(Double(Self.fanSteps[i])))])
            }
        }
        .padding(.horizontal, Theme.space).padding(.vertical, 12)
    }

    private func stepButtons(_ items: [(label: String, on: Bool, key: String)], onTap: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Button { Haptics.tap(); onTap(i) } label: {
                    Text(item.label).font(.subheadline.weight(item.on ? .semibold : .regular))
                        .foregroundStyle(item.on ? Theme.accentText : Theme.text)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(item.on ? Theme.accent : Theme.input)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!busy.isEmpty)
                .accessibilityAddTraits(item.on ? .isSelected : [])
            }
        }
    }

    private func heaterSheet(_ t: L10n, _ id: String) -> some View {
        let heater = caps?.heaters.first { $0.id == id }
        let low = id == "nozzle" ? 150 : 30  // below that nobody sets a target
        let top = Int(heater?.max ?? 0)
        var choices = [Choice(value: "0", label: t(.off))]
        if top >= low {
            choices += stride(from: low, through: top, by: 5).map { Choice(value: String($0), label: "\($0) °C") }
        }
        let current = status?.heaters[id]?.target.map { String(Int($0.rounded())) }
        return PickerSheet(title: "\(t.heaterName(id)) · \(t(.setTarget))", choices: choices, selected: current,
                           searchLabel: t(.search), closeLabel: "OK") { v in
            if let value = Double(v) { request("heater:\(id)", [Change(kind: .heater, id: id, value: .number(value))]) }
        }
    }

    // MARK: sending

    /// Asks first when a print runs (heaters, fan off) or a temperature is unusually high, then sends.
    private func request(_ key: String, _ changes: [Change]) {
        let t = app.l10n
        let risky = changes.contains { Self.isRisky($0) }
        if printing && risky {
            question = Question(text: t(.confirmDuringPrint), destructive: true) {
                Task { await send(key, changes, confirm: true) }
            }
            return
        }
        if let h = changes.first(where: { Self.isHigh($0) }), case .number(let v) = h.value {
            question = Question(text: t(.confirmHigh, ["name": t.heaterName(h.id), "v": String(Int(v))]), destructive: false) {
                Task { await send(key, changes, confirm: false) }
            }
            return
        }
        Task { await send(key, changes, confirm: false) }
    }

    static func isRisky(_ c: Change) -> Bool {
        c.kind == .heater || (c.kind == .fan && c.value == .number(0))
    }

    static func isHigh(_ c: Change) -> Bool {
        guard c.kind == .heater, case .number(let v) = c.value else { return false }
        return v >= (high[c.id] ?? .infinity)
    }

    private func send(_ key: String, _ changes: [Change], confirm: Bool) async {
        guard let api = app.api else { return }
        busy = key
        defer { busy = "" }
        for (i, ch) in changes.enumerated() {
            do {
                try await api.adjust(printer: printer, kind: ch.kind, id: ch.id, value: ch.value, confirm: confirm)
            } catch let e as APIError where e.status == 409 && !confirm {
                // the print started after our last status poll: ask now, and only send again after the user agrees
                let rest = Array(changes[i...])
                question = Question(text: app.l10n(.confirmDuringPrint), destructive: true) {
                    Task { await send(key, rest, confirm: true) }
                }
                return
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        error = ""
        await loadStatus()
    }

    // MARK: loading

    private func loadControls() async {
        guard let api = app.api else { return }
        do { caps = try await api.controls(printer: printer) } catch { self.error = error.localizedDescription }
    }

    private func loadPower() async {
        guard let api = app.api else { return }
        power = try? await api.power(printer: printer)
    }

    /// Older servers / bridges (before 0.43.0) answer 404: no motion sections then.
    private func loadMotion() async {
        guard let api = app.api else { return }
        if let m = try? await api.motionInfo(printer: printer), m.supported, !m.isEmpty { motion = m }
    }

    private func loadStatus() async {
        guard let api = app.api else { return }
        do {
            status = try await api.status(printer: printer)
            if caps != nil { error = "" }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Status every 3 s while visible: the server also records it as temperature history when the printer keeps none.
    private func pollStatus() async {
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
            await loadStatus()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func pollHistory() async {
        guard scenePhase == .active, let api = app.api else { return }
        while !Task.isCancelled {
            if let h = try? await api.temperatures(printer: printer) { history = h }
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

/// Temperature history as a line chart: actual solid, target dashed, one colour per heater.
struct TempChart: View {
    let series: [String: [TempHistory.Point]]

    @Environment(AppModel.self) private var app

    static func color(_ heater: String) -> Color {
        switch heater {
        case "nozzle": return Color(hex: 0xFF8A00)
        case "bed": return Color(hex: 0x2F6FED)
        case "chamber": return Color(hex: 0x2DB84D)
        default: return Theme.accent
        }
    }

    private struct Line: Identifiable {
        var heater: String
        var target: Bool
        var points: [(x: Double, y: Double)]
        var id: String { "\(heater)-\(target)" }
    }

    /// Heaters with at least two points, oldest point in minutes (≤ -1), upper end of the scale.
    static func scale(_ series: [String: [TempHistory.Point]]) -> (names: [String], minMinutes: Double, maxValue: Double) {
        let names = series.keys.filter { (series[$0]?.count ?? 0) > 1 }.sorted()
        var tMin = -60.0, vMax = 0.0
        for n in names {
            for p in series[n] ?? [] {
                tMin = min(tMin, p.t)
                vMax = max(vMax, p.actual ?? 0, p.target ?? 0)
            }
        }
        return (names, tMin / 60, max(50, ((vMax + 5) / 50).rounded(.up) * 50))
    }

    var body: some View {
        let t = app.l10n
        let (names, minMinutes, maxValue) = Self.scale(series)
        if names.isEmpty {
            Text(t(.historyEmpty)).font(.footnote).foregroundStyle(Theme.sub).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let lines = names.flatMap { n -> [Line] in
                let pts = series[n] ?? []
                var out = [Line(heater: n, target: false,
                                points: pts.compactMap { p in p.actual.map { (x: p.t / 60, y: $0) } })]
                let target: [(x: Double, y: Double)] = pts.compactMap { p in
                    guard let v = p.target, v > 0 else { return nil }
                    return (x: p.t / 60, y: v)
                }
                if !target.isEmpty { out.append(Line(heater: n, target: true, points: target)) }
                return out
            }
            VStack(alignment: .leading, spacing: 8) {
                Chart {
                    ForEach(lines) { line in
                        ForEach(Array(line.points.enumerated()), id: \.offset) { _, p in
                            LineMark(x: .value("min", p.x), y: .value("°C", p.y), series: .value("line", line.id))
                                .foregroundStyle(Self.color(line.heater))
                                .lineStyle(line.target ? StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                                                       : StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                                .opacity(line.target ? 0.7 : 1)
                        }
                    }
                }
                .chartXScale(domain: minMinutes...0)
                .chartYScale(domain: 0...maxValue)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, maxValue / 2, maxValue]) { v in
                        AxisGridLine()
                        AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))°") } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: [minMinutes, 0]) { v in
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(d < 0 ? t(.minutesAgo, ["m": String(Int((-d).rounded()))]) : "0")
                            }
                        }
                    }
                }
                .frame(height: 180)
                .accessibilityLabel(t(.temperatures))

                FlowLayout(spacing: 14) {
                    ForEach(names, id: \.self) { n in
                        HStack(spacing: 6) {
                            Capsule().fill(Self.color(n)).frame(width: 14, height: 3)
                            Text(t.heaterName(n)).font(.caption).foregroundStyle(Theme.sub)
                        }
                    }
                    Text("— \(t(.actual))  ┄ \(t(.target))").font(.caption).foregroundStyle(Theme.sub)
                }
            }
        }
    }
}
