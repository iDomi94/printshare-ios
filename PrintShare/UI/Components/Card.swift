import SwiftUI

/// Rounded white/grey container (Card in the Expo app).
struct PSCard<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

struct PSDivider: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, Theme.space)
    }
}

/// Small caps title above a card, optional footer below.
struct PSSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).textCase(.uppercase).font(.footnote).foregroundStyle(Theme.sub)
                    .padding(.leading, Theme.space).accessibilityAddTraits(.isHeader)
            }
            PSCard { VStack(spacing: 0) { content } }
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(Theme.sub).padding(.horizontal, Theme.space)
            }
        }
        .padding(.bottom, 22)
    }
}

/// A list row: label on the left, value / control on the right.
struct PSRow<Right: View>: View {
    var icon: String?
    var label: String
    var value: String?
    var sub: String?
    var danger = false
    var chevron: Bool?
    var action: (() -> Void)?
    @ViewBuilder var right: Right

    private var showChevron: Bool { chevron ?? (action != nil) }

    private var rowContent: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon).font(.title3).frame(width: 26)
                    .foregroundStyle(danger ? Theme.danger : Theme.accent).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.body).foregroundStyle(danger ? Theme.danger : Theme.text)
                if let sub { Text(sub).font(.footnote).foregroundStyle(Theme.sub) }
            }
            Spacer(minLength: 8)
            if let value { Text(value).font(.body).foregroundStyle(Theme.sub).lineLimit(2).multilineTextAlignment(.trailing) }
            right
            if showChevron {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.sub)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.space)
        .padding(.vertical, 13)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }

    var body: some View {
        if let action {
            Button { Haptics.tap(); action() } label: { rowContent }.buttonStyle(RowPressStyle())
        } else {
            rowContent
        }
    }
}

extension PSRow where Right == EmptyView {
    init(icon: String? = nil, label: String, value: String? = nil, sub: String? = nil, danger: Bool = false,
         chevron: Bool? = nil, action: (() -> Void)? = nil) {
        self.init(icon: icon, label: label, value: value, sub: sub, danger: danger, chevron: chevron, action: action,
                  right: { EmptyView() })
    }
}

struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Theme.input : Color.clear)
    }
}

/// Label + control stacked, used inside a card.
struct PSField<Content: View>: View {
    var label: String
    var hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(.body).foregroundStyle(Theme.text)
                Spacer()
                if let hint { Text(hint).font(.subheadline).foregroundStyle(Theme.sub) }
            }
            content
        }
        .padding(.horizontal, Theme.space).padding(.vertical, 12)
    }
}

struct PSStat: View {
    var label: String
    var value: String
    var sub: String?

    var body: some View {
        PSCard(padding: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.footnote).foregroundStyle(Theme.sub)
                Text(value).font(.title3.bold()).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.6)
                if let sub { Text(sub).font(.footnote).foregroundStyle(Theme.sub) }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
