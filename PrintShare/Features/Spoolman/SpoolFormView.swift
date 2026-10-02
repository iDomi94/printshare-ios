import SwiftUI

/// One cloud spool (server 0.17.0): brand, name, material, colour, weights, location; copy, archive, delete.
/// `id == SpoolFormView.new` adds one; `copy` starts from an existing spool (a stack of identical spools).
struct SpoolFormView: View {
    static let new = "new"
    static let materials = ["PLA", "PLA+", "PETG", "ABS", "ASA", "TPU", "PA", "PC", "PLA-CF", "PETG-CF", "PA-CF", "PVA", "HIPS"]
    static let colors = ["#000000", "#FFFFFF", "#808080", "#C0C0C0", "#E53935", "#FB8C00", "#FDD835", "#43A047", "#1E88E5",
                         "#8E24AA", "#6D4C41", "#F48FB1"]

    let id: String
    let copy: Int?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false
    @State private var vendor = ""
    @State private var name = ""
    @State private var material = "PLA"
    @State private var color = "#000000"
    @State private var weight = "1000"
    @State private var remaining = ""
    @State private var location = ""
    @State private var comment = ""
    @State private var archived = false
    @State private var busy = false
    @State private var error = ""
    @State private var confirmDelete = false

    private var isNew: Bool { id == Self.new }

    /// "1000", "12,5" -> number; nil for empty or invalid input.
    static func number(_ v: String) -> Double? {
        let s = v.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, let n = Double(s), n.isFinite, n >= 0 else { return nil }
        return n
    }

    /// "#RRGGBB" in capitals, nil when it isn't a colour.
    static func hex(_ v: String) -> String? {
        let s = v.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        return s.matches("^[0-9A-Fa-f]{6}$") ? "#" + s.uppercased() : nil
    }

    private var valid: Bool {
        Self.hex(color) != nil && (weight.trimmingCharacters(in: .whitespaces).isEmpty || Self.number(weight) != nil)
            && (remaining.trimmingCharacters(in: .whitespaces).isEmpty || Self.number(remaining) != nil)
    }

    var body: some View {
        let t = app.l10n
        Group {
            if loaded { form(t) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg) }
        }
        .navigationTitle(isNew ? t(.spoolNew) : t(.spoolEdit, ["id": id]))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert(t(.spoolDeleteQ, ["id": id]), isPresented: $confirmDelete) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.del), role: .destructive) { Task { await remove() } }
        }
    }

    private func field(_ label: String, _ text: Binding<String>, placeholder: String = "", caps: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.body).foregroundStyle(Theme.text).frame(width: 120, alignment: .leading)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(caps ? .characters : .never).autocorrectionDisabled()
                .accessibilityLabel(label)
        }
        .padding(.horizontal, Theme.space).padding(.vertical, 14)
    }

    private func numberField(_ label: String, _ text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label).font(.body).foregroundStyle(Theme.text)
            Spacer()
            TextField(placeholder, text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .frame(maxWidth: 100).accessibilityLabel(label)
        }
        .padding(.horizontal, Theme.space).padding(.vertical, 14)
    }

    private func form(_ t: L10n) -> some View {
        let hex = Self.hex(color)
        return PSScreen {
            if !error.isEmpty { PSBanner(kind: .error, text: error) }

            PSSection {
                field(t(.spoolVendor), $vendor, placeholder: "Elegoo")
                PSDivider()
                field(t(.spoolName), $name, placeholder: "Rapid PLA+ Black")
            }

            PSSection(title: t(.spoolMaterial)) {
                FlowChips(items: Self.materials, selected: material) { material = $0 }.padding(12)
                PSDivider()
                field(t(.spoolOther), $material, caps: true)
            }

            PSSection(title: t(.spoolColor)) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 10)], spacing: 10) {
                    ForEach(Self.colors, id: \.self) { c in
                        Button { Haptics.tap(); color = c } label: {
                            Circle().fill(Color(hexString: c) ?? Theme.track).frame(width: 34, height: 34)
                                .overlay(Circle().stroke(hex == c ? Theme.accent : Theme.line, lineWidth: hex == c ? 3 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c)
                        .accessibilityAddTraits(hex == c ? .isSelected : [])
                    }
                }
                .padding(12)
                PSDivider()
                HStack {
                    field("Hex", $color, placeholder: "#RRGGBB", caps: true)
                    ColorDot(color: Color(hexString: hex), size: 26).padding(.trailing, Theme.space)
                }
            }

            PSSection(footer: t(.spoolRemainingHint)) {
                numberField(t(.spoolWeight), $weight, placeholder: "1000")
                PSDivider()
                numberField(t(.spoolRemaining), $remaining, placeholder: weight.isEmpty ? "–" : weight)
            }

            PSSection {
                field(t(.spoolLocation), $location)
                PSDivider()
                field(t(.spoolComment), $comment)
            }

            if !isNew {
                PSSection {
                    PSRow(icon: "doc.on.doc", label: t(.spoolCopy)) {
                        if let n = Int(id) { app.replaceTop(with: .spool(id: Self.new, copy: n)) }
                    }
                    PSDivider()
                    PSRow(icon: "archivebox", label: t(archived ? .spoolUnarchive : .spoolArchive)) {
                        Task { await save(archive: !archived) }
                    }
                    PSDivider()
                    PSRow(icon: "trash", label: t(.spoolDelete), danger: true) { confirmDelete = true }
                }
            }
        } footer: {
            PSButton(title: t(.save), icon: "checkmark", loading: busy, disabled: !valid) { Task { await save() } }
        }
    }

    private func load() async {
        guard !loaded else { return }
        defer { loaded = true }
        let from = isNew ? copy : Int(id)
        guard let from, let sm = app.openSpoolman(Spoolman.cloudSetting) else { return }
        do {
            guard let s = try await sm.spools(archived: true).first(where: { $0.id == from }) else { return }
            vendor = s.vendor ?? ""
            name = s.name
            material = s.material ?? ""
            color = s.color ?? "#000000"
            weight = s.filamentG.map(Format.trimNumber) ?? ""
            location = s.location ?? ""
            comment = isNew ? "" : s.comment ?? ""
            if !isNew {
                remaining = s.remainingG.map(Format.trimNumber) ?? ""
                archived = s.archived
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Same body as the Expo app; empty fields are cleared.
    func input(archive: Bool? = nil) -> SpoolInput {
        func clean(_ s: String) -> String? {
            let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        return SpoolInput(filament: .init(name: clean(name), vendor: clean(vendor), material: clean(material),
                                          colorHex: Self.hex(color), weight: Self.number(weight)),
                          remainingWeight: clean(remaining) != nil ? Self.number(remaining) : nil,
                          location: clean(location), comment: clean(comment), archived: archive)
    }

    private func save(archive: Bool? = nil) async {
        guard let sm = app.openSpoolman(Spoolman.cloudSetting) else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            if isNew { _ = try await sm.create(input()) } else if let n = Int(id) { _ = try await sm.update(n, input(archive: archive)) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() async {
        guard let sm = app.openSpoolman(Spoolman.cloudSetting), let n = Int(id) else { return }
        do {
            try await sm.remove(n)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Wrapping row of selectable chips (materials).
private struct FlowChips: View {
    var items: [String]
    var selected: String
    var onPick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { m in
                let on = m == selected
                Button { Haptics.tap(); onPick(m) } label: {
                    Text(m).font(.subheadline).foregroundStyle(on ? Theme.accentText : Theme.text)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(on ? Theme.accent : Theme.input)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
