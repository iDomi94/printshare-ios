import SwiftUI

/// Search Printables / Thingiverse / own Manyfold and open a model (spec MQ-05). MakerWorld can't be searched from
/// outside (server 0.17.1): a card sends the user there, and a MakerWorld link typed here opens its model page.
struct DiscoverView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var sources: [Source] = []
    @State private var source = "printables"
    @State private var sort: SortKey = .relevant
    @State private var input = ""
    @State private var query = ""
    @State private var hits: [ModelHit] = []
    @State private var page = 1
    @State private var more = false
    @State private var loading = false
    @State private var error = ""
    @State private var requestToken = 0

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12, alignment: .top)]

    var body: some View {
        let t = app.l10n
        Group {
            if app.server == nil {
                PSEmpty(icon: "magnifyingglass", title: t(.notConnectedTitle), sub: t(.notConnectedSub))
                    .frame(maxHeight: .infinity).background(Theme.bg)
            } else {
                content(t)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func content(_ t: L10n) -> some View {
        let available = sources.filter(\.available)
        // only the owner of a home server can add the token; cloud users can't do anything about it
        let tvMissing = !app.isCloud && sources.contains { $0.id == "thingiverse" && !$0.available }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(t(.discoverTitle)).font(.largeTitle.bold()).foregroundStyle(Theme.text)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Button { Haptics.tap(); app.push(.printablesWeb) } label: {
                        Label(t(.printablesWebOpen), systemImage: "safari").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .padding(.top, 12).padding(.bottom, 2)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.sub).accessibilityHidden(true)
                    TextField(t(.searchPlaceholder), text: $input)
                        .submitLabel(.search).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onSubmit { submit(input) }
                        .accessibilityLabel(t(.searchPlaceholder))
                    if !input.isEmpty {
                        Button { input = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.sub) }
                            .accessibilityLabel(t(.cancelBtn))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 13)
                .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if available.count > 1 {
                    Picker("", selection: Binding(get: { source }, set: { changeSource($0) })) {
                        ForEach(available) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                // own Manyfold library: no likes or makes to sort by
                if source != "manyfold" { sortChips(t) }
                if !error.isEmpty { PSBanner(kind: .error, text: error) }

                if hits.isEmpty { emptyState(t, tvMissing: tvMissing) }
                else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(hits) { h in
                            card(h).onAppear { if h.id == hits.last?.id, more, !loading { load(query, page + 1) } }
                        }
                    }
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding(24) }
            }
            .padding(Theme.space).padding(.bottom, 24)
            .frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Theme.bg)
        .task { await loadSources() }
    }

    private func sortChips(_ t: L10n) -> some View {
        HStack(spacing: 8) {
            ForEach(SortKey.allCases, id: \.self) { k in
                let on = k == sort
                Button { Haptics.tap(); changeSort(k) } label: {
                    Text(t(k == .relevant ? .sortRelevant : k == .popular ? .sortPopular : .sortMakes))
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.accentText : Theme.text)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(on ? Theme.accent : Theme.card).clipShape(Capsule())
                }
                .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func emptyState(_ t: L10n, tvMissing: Bool) -> some View {
        if loading {
            EmptyView()
        } else if !query.isEmpty {
            PSEmpty(icon: "magnifyingglass", title: t(.noResults), sub: t(.noResultsSub))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(t(.suggestions)).textCase(.uppercase).font(.footnote).foregroundStyle(Theme.sub).padding(.leading, 4)
                FlowLayout(spacing: 8) {
                    ForEach(t.suggestions, id: \.self) { s in
                        Button { Haptics.tap(); submit(s) } label: {
                            Text(s).font(.subheadline).foregroundStyle(Theme.text)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(Theme.card).clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                PSCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(t(.makerworldTitle), systemImage: "globe").font(.headline).foregroundStyle(Theme.text)
                        Text(t(.makerworldText)).font(.subheadline).foregroundStyle(Theme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        PSButton(title: t(.makerworldOpen), kind: .secondary, icon: "arrow.up.right.square") {
                            if let u = URL(string: "https://makerworld.com") { openURL(u) }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.top, 16)
                if tvMissing {
                    Text(t(.thingiverseHint)).font(.footnote).foregroundStyle(Theme.sub).padding(.top, 14)
                }
            }
            .padding(.top, 8)
        }
    }

    private func card(_ h: ModelHit) -> some View {
        Button { Haptics.tap(); app.push(.model(source: h.source, id: h.id)) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .overlay { RemoteImage(url: h.thumbnail) }
                    .clipped()
                VStack(alignment: .leading, spacing: 3) {
                    Text(h.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if let a = h.author { Text(a).font(.footnote).foregroundStyle(Theme.sub).lineLimit(1) }
                    HStack(spacing: 10) {
                        if let l = h.likes { Text("♥ \(Format.compact(l))") }
                        if let d = h.downloads { Text("↓ \(Format.compact(d))") }
                    }
                    .font(.caption).foregroundStyle(Theme.sub).padding(.top, 3)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(h.name)
    }

    // MARK: loading

    private func loadSources() async {
        guard let api = app.api else { return }
        sources = (try? await api.sources()) ?? []
    }

    private func load(_ q: String, _ p: Int, source src: String? = nil, sort srt: SortKey? = nil) {
        guard let api = app.api, !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        requestToken += 1
        let token = requestToken
        let source = src ?? self.source, sort = srt ?? self.sort
        loading = true
        error = ""
        Task {
            do {
                let r = try await api.search(query: q, source: source, page: p, sort: sort)
                guard token == requestToken else { return }
                if p == 1 { hits = r.results } else {
                    let seen = Set(hits.map(\.id))
                    hits += r.results.filter { !seen.contains($0.id) }
                }
                page = p
                more = r.hasMore
            } catch {
                if token == requestToken { self.error = error.localizedDescription }
            }
            if token == requestToken { loading = false }
        }
    }

    private func submit(_ text: String) {
        let v = text.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return }
        if let mw = Format.makerWorldId(Format.extractLink(v)) {
            input = ""
            app.push(.model(source: "makerworld", id: mw))
            return
        }
        input = v
        if v != query { hits = [] }
        query = v
        load(v, 1)
    }

    private func changeSource(_ v: String) {
        source = v
        hits = []
        load(query, 1, source: v)
    }

    private func changeSort(_ k: SortKey) {
        sort = k
        load(query, 1, sort: k)
    }
}

/// Remote image with a grey placeholder (list thumbnails and gallery). Server-relative addresses ("/api/…", Manyfold
/// previews, server 0.21.0) are completed with the server address and key.
struct RemoteImage: View {
    var url: String?

    @Environment(AppModel.self) private var app
    @State private var resolved: URL?

    var body: some View {
        Group {
            if let u = resolved ?? direct {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: Theme.track
                    }
                }
            } else {
                Theme.track
            }
        }
        .task(id: url) {
            guard let url, url.hasPrefix("/api/"), let api = app.api else { resolved = nil; return }
            resolved = await api.imageURL(url)
        }
    }

    private var direct: URL? {
        guard let url, !url.hasPrefix("/api/") else { return nil }
        return URL(string: url)
    }
}

/// Wrapping row of chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
