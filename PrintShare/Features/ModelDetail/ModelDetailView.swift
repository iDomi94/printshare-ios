import SwiftUI

/// Model details from Printables / Thingiverse -> prepare print (spec MQ-06, MQ-10). MakerWorld (server 0.17.1): only
/// downloadable with the user's own account -> button to MakerWorld, the 3MF comes back through the share menu.
struct ModelDetailView: View {
    let source: String
    let id: String

    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var model: ModelDetail?
    @State private var error = ""
    @State private var slide = 0
    @State private var expanded = false
    @State private var attempt = 0
    @State private var showFiles = false

    private static let sourceNames = ["printables": "Printables", "thingiverse": "Thingiverse", "makerworld": "MakerWorld",
                                              "manyfold": "Manyfold"]

    var body: some View {
        let t = app.l10n
        Group {
            if let model { detail(t, model) } else { placeholder(t) }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) { await load() }
        .sheet(isPresented: $showFiles) {
            if let m = model {
                ModelFilesSheet(link: m.hit.sliceLink) { f in
                    showFiles = false
                    app.push(.prepare(PrepareArgs(link: m.hit.sliceLink, fileName: m.hit.link != nil ? m.hit.name : nil,
                                                  edit: EditArgs(file: String(f.index)))))
                }
            }
        }
    }

    private func placeholder(_ t: L10n) -> some View {
        VStack {
            if error.isEmpty {
                ProgressView().controlSize(.large)
            } else {
                PSEmpty(icon: "icloud.slash", title: error) {
                    PSButton(title: t(.tryAgain), kind: .secondary) { attempt += 1 }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
    }

    private func detail(_ t: L10n, _ m: ModelDetail) -> some View {
        let sliceable = m.files.filter(\.sliceable).count
        let r = m.recommended
        let text = [m.summary, m.description].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let long = text.count > 400
        let srcName = Self.sourceNames[m.hit.source] ?? m.hit.source
        var openFiles: (() -> Void)?
        if sliceable > 0 { openFiles = { showFiles = true } }
        return PSScreen {
            if !m.images.isEmpty { gallery(m.images) }

            Text(m.hit.name).font(.title.bold()).foregroundStyle(Theme.text)
            HStack(spacing: 8) {
                if let a = m.hit.author { Text(t(.by, ["author": a])).font(.subheadline).foregroundStyle(Theme.sub) }
                PSBadge(text: srcName, kind: .accent)
            }
            .padding(.top, 6).padding(.bottom, 16)

            stats(t, m.hit)

            if m.external { PSBanner(kind: .info, text: t(.externalDownload, ["source": srcName])) }

            PSSection {
                if !m.external {
                    PSRow(icon: "doc", label: sliceable == 1 ? t(.printableFile)
                          : sliceable > 0 ? t(.printableFiles, ["n": String(sliceable)]) : t(.noPrintableFiles),
                          action: openFiles)
                }
                if let l = m.hit.license, !l.isEmpty {
                    if !m.external { PSDivider() }
                    PSRow(icon: "rosette", label: t(.license), sub: l)
                }
                if let c = m.category, !c.isEmpty { PSDivider(); PSRow(icon: "tag", label: t(.category), value: c) }
            }

            if !r.isEmpty {
                let rows = recommendedRows(t, r)
                PSSection(title: t(.authorSettings)) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        if i > 0 { PSDivider() }
                        PSRow(label: row.0, value: row.1)
                    }
                }
            }

            if !m.variants.isEmpty {
                PSSection(title: t(.variants)) {
                    ForEach(Array(m.variants.enumerated()), id: \.element.id) { i, v in
                        if i > 0 { PSDivider() }
                        PSRow(label: v.title.isEmpty ? "#\(v.id)" : v.title, sub: Self.variantLine(t, v), right: {
                            HStack(spacing: 3) {
                                ForEach(Array(v.colors.prefix(6).enumerated()), id: \.offset) { _, c in
                                    ColorDot(color: Color(hexString: c), size: 12)
                                }
                            }
                            .padding(.leading, 8)
                        })
                    }
                }
            }

            if !text.isEmpty {
                PSSection(title: t(.description)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text).font(.subheadline).foregroundStyle(Theme.text)
                            .lineLimit(expanded || !long ? nil : 8)
                        if long {
                            Button { Haptics.tap(); expanded.toggle() } label: {
                                Text(t(expanded ? .showLess : .showMore)).font(.subheadline).foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .padding(Theme.space).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } footer: {
            if m.external {
                PSButton(title: t(.openOn, ["source": srcName]), icon: "arrow.up.right.square") {
                    if let u = URL(string: m.hit.url) { openURL(u) }
                }
            } else {
                PSButton(title: t(.printThis), icon: "printer", disabled: sliceable == 0) {
                    app.push(.prepare(PrepareArgs(link: m.hit.sliceLink, fileName: m.hit.link != nil ? m.hit.name : nil)))
                }
                PSButton(title: t(.openOn, ["source": srcName]), kind: .plain, icon: "arrow.up.right.square") {
                    if let u = URL(string: m.hit.url) { openURL(u) }
                }
            }
        }
    }

    private static func hours(_ h: Double) -> String {
        "\(Int(h)) h \(Int(((h - h.rounded(.down)) * 60).rounded())) min"
    }

    /// "PLA, PETG · 42 g · 2 h 10 min · AMS"
    static func variantLine(_ t: L10n, _ v: ModelVariant) -> String {
        var parts: [String] = []
        if !v.materials.isEmpty { parts.append(v.materials.joined(separator: ", ")) }
        if let w = v.weightG, w > 0 { parts.append("\(Format.trimNumber(w)) g") }
        if let h = v.printHours, h > 0 { parts.append(hours(h)) }
        if v.needsAms { parts.append(t(.needsAms)) }
        return parts.joined(separator: " · ")
    }

    private func recommendedRows(_ t: L10n, _ r: Recommended) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let v = r.material { rows.append((t(.material), v)) }
        if let v = r.nozzle { rows.append((t(.nozzle), v)) }
        if let v = r.layerHeight { rows.append((t(.layerHeight), v)) }
        if let w = r.weightG, w > 0 { rows.append((t(.weight), "\(Int(w.rounded())) g")) }
        if let h = r.printHours, h > 0 { rows.append((t(.printTimeAuthor), Self.hours(h))) }
        return rows
    }

    private func gallery(_ images: [String]) -> some View {
        VStack(spacing: 8) {
            TabView(selection: $slide) {
                ForEach(Array(images.enumerated()), id: \.offset) { i, url in
                    Color.clear.overlay { RemoteImage(url: url) }.clipped().tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if images.count > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<min(images.count, 12), id: \.self) { i in
                        Circle().fill(i == slide ? Theme.accent : Theme.track).frame(width: 7, height: 7)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.bottom, 14)
    }

    private func stats(_ t: L10n, _ h: ModelHit) -> some View {
        var items: [(String, Int, L10nKey)] = []
        if let v = h.likes { items.append(("heart", v, L10nKey.likes)) }
        if let v = h.downloads { items.append(("arrow.down.circle", v, L10nKey.downloads)) }
        if let v = h.makes { items.append(("hammer", v, L10nKey.makes)) }
        return HStack(spacing: 22) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let (icon, value, key) = item
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: icon).font(.footnote).foregroundStyle(Theme.sub)
                        Text(Format.compact(value)).font(.headline).foregroundStyle(Theme.text)
                    }
                    Text(t(key)).font(.caption).foregroundStyle(Theme.sub)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 4).padding(.bottom, 20)
    }

    private func load() async {
        guard let api = app.api else { return }
        error = ""
        do { model = try await api.model(source: source, id: id) }
        catch { self.error = error.localizedDescription }
    }
}
