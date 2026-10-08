import SwiftUI

/// Moving the printer by hand (server 0.43.0 / 0.44.0): home, jog pad for X/Y/Z, extrude / retract, load / unload and the
/// printer's own macros. Part of the control page; everything is locked while a print runs (the server answers 409 too).
/// Load / unload / macros ask first, and nothing is sent twice without the user tapping again.
struct MotionPanel: View {
    let printer: String
    let caps: Motion
    let printing: Bool
    /// Current nozzle temperature, for the "too cold to extrude" hint.
    let nozzle: Double?
    /// Heats the nozzle for extruding (the page's own heater change, with its checks).
    let onHeat: () -> Void

    static let extrudeSteps: [Double] = [5, 10, 25, 50]
    /// Firmware refuses to extrude colder than this (Klipper `min_extrude_temp`).
    static let hotEnough = 170.0
    /// Centauri and others: load / unload without a chosen material use PLA.
    static let defaultMaterial = "PLA"

    private enum Pick { case material, slot }

    @Environment(AppModel.self) private var app
    @State private var step: Double = 10
    @State private var amount: Double = 10
    @State private var busy = ""
    @State private var error = ""
    @State private var done = ""
    @State private var material = MotionPanel.defaultMaterial
    @State private var pick: Pick?
    @State private var question: Question?

    private struct Question: Identifiable {
        let id = UUID()
        var text: String
        var onConfirm: @MainActor () -> Void
    }

    private var steps: [Double] { caps.jog?.steps ?? [] }
    private var locked: Bool { printing || !busy.isEmpty }
    private var cold: Bool { (nozzle ?? Self.hotEnough) < Self.hotEnough }
    private var loadTemp: Int { caps.materials.first { $0.name == material }?.loadTemp ?? 220 }

    var body: some View {
        let t = app.l10n
        Group {
            if !error.isEmpty { PSBanner(kind: .error, text: error).padding(.bottom, 12) }
            if !done.isEmpty { PSBanner(kind: .ok, text: done).padding(.bottom, 12) }
            if !caps.home.isEmpty || caps.jog != nil { moveSection(t) }
            if caps.extrude || caps.load || caps.unload { extruderSection(t) }
            if !caps.macros.isEmpty { macroSection(t) }
        }
        .onAppear { if !steps.contains(step) { step = steps.contains(10) ? 10 : steps.first ?? 1 } }
        .sheet(item: Binding(get: { pick.map { PickItem(kind: $0) } }, set: { if $0 == nil { pick = nil } })) { item in
            pickSheet(t, item.kind)
        }
        .alert(question?.text ?? "", isPresented: Binding(get: { question != nil }, set: { if !$0 { question = nil } }),
               presenting: question) { q in
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.motionGo)) { q.onConfirm() }
        }
    }

    private struct PickItem: Identifiable { var kind: Pick; var id: Int { kind == .material ? 0 : 1 } }

    // MARK: sections

    private func moveSection(_ t: L10n) -> some View {
        PSSection(title: t(.motionTitle), footer: t(.motionHint)) {
            if !caps.home.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(caps.home, id: \.self) { axis in
                        PSButton(title: axis == "XYZ" ? t(.homeAll) : "\(t(.home)) \(axis)", kind: .secondary,
                                 icon: "house", loading: busy == "home:\(axis)", disabled: locked) {
                            run("home:\(axis)", .home(axis))
                        }
                    }
                }
                .padding(12)
            }
            if let jog = caps.jog {
                if !caps.home.isEmpty { PSDivider() }
                VStack(spacing: 14) {
                    segmented(steps, selection: step, label: { Self.mm($0) }) { step = $0 }
                    HStack(alignment: .center, spacing: 28) {
                        VStack(spacing: 6) {
                            pad(jog, "Y", 1, "arrow.up", "Y+")
                            HStack(spacing: 6) {
                                pad(jog, "X", -1, "arrow.left", "X−")
                                Text("X / Y").font(.footnote).foregroundStyle(Theme.sub).frame(width: 64, height: 56)
                                pad(jog, "X", 1, "arrow.right", "X+")
                            }
                            pad(jog, "Y", -1, "arrow.down", "Y−")
                        }
                        VStack(spacing: 6) {
                            pad(jog, "Z", 1, "chevron.up", "Z+")
                            Text("Z").font(.footnote).foregroundStyle(Theme.sub).frame(width: 64, height: 56)
                            pad(jog, "Z", -1, "chevron.down", "Z−")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(12)
            }
            if caps.motorsOff {
                PSDivider()
                PSRow(icon: "power", label: t(.motorsOff), sub: t(.motorsOffSub),
                      chevron: false, action: locked ? nil : { run("motors_off", .motorsOff) }) {
                    if busy == "motors_off" { ProgressView().padding(.leading, 8) }
                }
            }
        }
        .opacity(printing ? 0.5 : 1)
    }

    private func extruderSection(_ t: L10n) -> some View {
        PSSection(title: t(.extruderTitle), footer: caps.extrude ? t(.extrudeHint, ["t": String(Int(Self.hotEnough))]) : nil) {
            if caps.extrude {
                VStack(alignment: .leading, spacing: 10) {
                    if cold {
                        PSBanner(kind: .warn, text: t(.extrudeCold, ["t": String(Int((nozzle ?? 0).rounded()))]))
                        PSButton(title: t(.extrudeHeat), kind: .secondary, icon: "flame", disabled: locked) { onHeat() }
                    }
                    segmented(Self.extrudeSteps, selection: amount, label: { Self.mm($0) }) { amount = $0 }
                    HStack(spacing: 8) {
                        PSButton(title: t(.retract), kind: .secondary, icon: "arrow.up", loading: busy == "retract",
                                 disabled: locked) { run("retract", .extrude(-amount)) }
                        PSButton(title: t(.extrude), kind: .secondary, icon: "arrow.down", loading: busy == "extrude",
                                 disabled: locked) { run("extrude", .extrude(amount)) }
                    }
                }
                .padding(12)
            }
            if caps.load || caps.unload {
                if caps.extrude { PSDivider() }
                if caps.filamentTemp && !caps.materials.isEmpty {
                    PSRow(icon: "thermometer.medium", label: t(.motionMaterial), value: "\(material) · \(loadTemp) °C",
                          action: locked ? nil : { pick = .material })
                    PSDivider()
                }
                HStack(spacing: 8) {
                    if caps.load {
                        PSButton(title: t(.motionLoad), kind: .secondary, icon: "square.and.arrow.down",
                                 loading: busy == "load", disabled: locked) {
                            if caps.loadSlots != nil { pick = .slot } else { askLoad(t, slot: nil) }
                        }
                    }
                    if caps.unload {
                        PSButton(title: t(.motionUnload), kind: .secondary, icon: "square.and.arrow.up",
                                 loading: busy == "unload", disabled: locked) {
                            ask(t(.motionUnloadQ, ["m": material, "t": String(loadTemp)])) {
                                run("unload", MotionAction(action: "unload", material: material, confirm: true))
                            }
                        }
                    }
                }
                .padding(12)
                if caps.filamentAsJob {
                    Text(t(.motionAsJob)).font(.footnote).foregroundStyle(Theme.sub)
                        .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
        }
        .opacity(printing ? 0.5 : 1)
    }

    private func macroSection(_ t: L10n) -> some View {
        PSSection(title: t(.macrosTitle), footer: t(.macrosHint)) {
            ForEach(Array(caps.macros.enumerated()), id: \.element) { i, name in
                if i > 0 { PSDivider() }
                PSRow(icon: "play.circle", label: name, chevron: false,
                      action: locked ? nil : {
                          ask(t(.macroQ, ["m": name])) {
                              run("macro:\(name)", MotionAction(action: "macro", macro: name, confirm: true))
                          }
                      }) {
                    if busy == "macro:\(name)" { ProgressView().padding(.leading, 8) }
                }
            }
        }
        .opacity(printing ? 0.5 : 1)
    }

    // MARK: pieces

    static func mm(_ v: Double) -> String { (v == v.rounded() ? String(Int(v)) : String(v)) + " mm" }

    private func segmented(_ values: [Double], selection: Double, label: @escaping (Double) -> String,
                           onTap: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(values, id: \.self) { v in
                let on = v == selection
                Button { Haptics.tap(); onTap(v) } label: {
                    Text(label(v)).font(.subheadline.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.accentText : Theme.text)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(on ? Theme.accent : Theme.input)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func pad(_ jog: Motion.Jog, _ axis: String, _ dir: Double, _ icon: String, _ label: String) -> some View {
        let can = jog.axes.contains(axis) && !locked
        let key = "jog:\(axis)\(dir > 0 ? "+" : "-")"
        return Button { Haptics.tap(); run(key, .jog(axis, dir * step)) } label: {
            Group {
                if busy == key { ProgressView() } else {
                    VStack(spacing: 2) {
                        Image(systemName: icon).font(.body.weight(.semibold))
                        Text(label).font(.caption.weight(.semibold))
                    }
                }
            }
            .foregroundStyle(Theme.text)
            .frame(width: 64, height: 56)
            .background(Theme.input)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!can)
        .opacity(can ? 1 : 0.4)
        .accessibilityLabel("\(axis) \(dir > 0 ? "+" : "−")\(Self.mm(step))")
    }

    private func pickSheet(_ t: L10n, _ kind: Pick) -> some View {
        switch kind {
        case .material:
            return PickerSheet(title: t(.motionMaterial),
                               choices: caps.materials.map { Choice(value: $0.name, label: $0.name, sub: "\($0.loadTemp) °C") },
                               selected: material, searchLabel: t(.search), closeLabel: "OK") { material = $0 }
        case .slot:
            let slots = caps.loadSlots ?? []
            return PickerSheet(title: t(.motionLoadSlot),
                               choices: slots.map { s in
                                   Choice(value: String(s.tool),
                                          label: s.tool == 254 ? t(.filamentExternal)
                                              : "\(t(.filamentSlot)) \(s.slotId ?? String(s.tool + 1))",
                                          sub: [s.material, s.name].compactMap { $0 }.filter { !$0.isEmpty }
                                              .joined(separator: " · "))
                               },
                               selected: nil, searchLabel: t(.search), closeLabel: "OK") { v in
                if let tool = Int(v) { askLoad(t, slot: tool) }
            }
        }
    }

    // MARK: sending

    private func ask(_ text: String, _ onConfirm: @escaping @MainActor () -> Void) {
        question = Question(text: text, onConfirm: onConfirm)
    }

    private func askLoad(_ t: L10n, slot: Int?) {
        ask(t(.motionLoadQ, ["m": material, "t": String(loadTemp)])) {
            run("load", MotionAction(action: "load", material: material, slot: slot, confirm: true))
        }
    }

    private func run(_ key: String, _ action: MotionAction) {
        guard let api = app.api, busy.isEmpty else { return }
        busy = key
        error = ""
        done = ""
        Task {
            defer { busy = "" }
            do {
                try await api.motion(printer: printer, action)
                if action.action != "jog" { done = app.l10n(.motionDone) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
