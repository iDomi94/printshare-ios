import SwiftUI

enum PSBannerKind { case info, warn, error, ok }

struct PSBanner: View {
    var kind: PSBannerKind = .info
    var text: String

    private var style: (bg: Color, fg: Color, icon: String) {
        switch kind {
        case .info: return (Theme.accentSoft, Theme.accent, "info.circle.fill")
        case .warn: return (Theme.warnSoft, Theme.warn, "exclamationmark.triangle.fill")
        case .error: return (Theme.dangerSoft, Theme.danger, "exclamationmark.circle.fill")
        case .ok: return (Theme.okSoft, Theme.ok, "checkmark.circle.fill")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.icon).foregroundStyle(style.fg).accessibilityHidden(true)
            Text(text).font(.subheadline).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(style.bg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }
}

enum PSBadgeKind { case neutral, ok, warn, error, accent }

struct PSBadge: View {
    var text: String
    var kind: PSBadgeKind = .neutral

    private var colors: (bg: Color, fg: Color) {
        switch kind {
        case .neutral: return (Theme.track, Theme.sub)
        case .ok: return (Theme.okSoft, Theme.ok)
        case .warn: return (Theme.warnSoft, Theme.warn)
        case .error: return (Theme.dangerSoft, Theme.danger)
        case .accent: return (Theme.accentSoft, Theme.accent)
        }
    }

    var body: some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(colors.fg)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(colors.bg).clipShape(Capsule())
    }
}

/// Icon + title + text, with optional actions below (Empty in the Expo app).
struct PSEmpty<Actions: View>: View {
    var icon: String
    var title: String
    var sub: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(Theme.sub).accessibilityHidden(true)
            Text(title).font(.headline).foregroundStyle(Theme.text).multilineTextAlignment(.center).padding(.top, 6)
            if let sub { Text(sub).font(.subheadline).foregroundStyle(Theme.sub).multilineTextAlignment(.center) }
            VStack(spacing: 8) { actions }.padding(.top, 14)
        }
        .padding(.vertical, 40).padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}

extension PSEmpty where Actions == EmptyView {
    init(icon: String, title: String, sub: String? = nil) {
        self.init(icon: icon, title: title, sub: sub, actions: { EmptyView() })
    }
}

typealias RefreshAction = @Sendable () async -> Void

/// Scrolling screen with a max content width and an optional footer pinned to the bottom (Screen in the Expo app).
struct PSScreen<Content: View, Footer: View>: View {
    var refresh: RefreshAction?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    private var scroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(Theme.space)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg)
    }

    var body: some View {
        Group {
            if let refresh { scroll.refreshable { await refresh() } } else { scroll }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if Footer.self != EmptyView.self {
                VStack(spacing: 10) { footer }
                    .padding(Theme.space).padding(.bottom, 4)
                    .frame(maxWidth: 640).frame(maxWidth: .infinity)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
                    // a ShapeStyle background reaches under the home indicator, so nothing scrolls through below the buttons
                    .background(Theme.bg, ignoresSafeAreaEdges: .bottom)
            }
        }
    }
}

extension PSScreen where Footer == EmptyView {
    init(refresh: RefreshAction? = nil, @ViewBuilder content: () -> Content) {
        self.init(refresh: refresh, content: content, footer: { EmptyView() })
    }
}
