import SwiftUI

enum PSButtonKind { case primary, secondary, danger, plain }

struct PSButton: View {
    var title: String
    var kind: PSButtonKind = .primary
    var icon: String?
    var loading = false
    var disabled = false
    var action: () -> Void

    private var colors: (bg: Color, fg: Color) {
        switch kind {
        case .primary: return (Theme.accent, Theme.accentText)
        case .secondary: return (Theme.accentSoft, Theme.accent)
        case .danger: return (Theme.dangerSoft, Theme.danger)
        case .plain: return (Color.clear, Theme.accent)
        }
    }

    var body: some View {
        let off = disabled || loading
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 8) {
                if loading {
                    ProgressView().tint(colors.fg)
                } else if let icon {
                    Image(systemName: icon).accessibilityHidden(true)
                }
                Text(title).font(.headline).multilineTextAlignment(.center)
            }
            .foregroundStyle(colors.fg)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 18)
            .padding(.vertical, 2)
            .background(colors.bg)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .opacity(off ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(off)
        .accessibilityLabel(title)
    }
}

/// Segmented choice with custom labels (values the server does not know are shown as they are).
struct PSSegmented<V: Hashable>: View {
    var values: [V]
    @Binding var selection: V
    var label: (V) -> String

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(values, id: \.self) { Text(label($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: selection) { _, _ in Haptics.tap() }
    }
}

struct PSStepper: View {
    var value: Int
    var range: ClosedRange<Int>
    var step = 1
    var format: (Int) -> String = { String($0) }
    var onChange: (Int) -> Void

    private func button(_ symbol: String, _ label: String, _ next: Int, off: Bool) -> some View {
        Button { Haptics.tap(); onChange(next) } label: {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                .frame(width: 44, height: 40).background(Theme.track)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain).disabled(off).opacity(off ? 0.35 : 1).accessibilityLabel(label)
    }

    var body: some View {
        HStack {
            button("minus", "−", max(range.lowerBound, value - step), off: value <= range.lowerBound)
            Text(format(value)).font(.headline).foregroundStyle(Theme.text).frame(minWidth: 72)
            button("plus", "+", min(range.upperBound, value + step), off: value >= range.upperBound)
        }
    }
}

struct PSProgressBar: View {
    var value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(Theme.accent).frame(width: geo.size.width * max(0, min(100, value)) / 100)
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityValue("\(Int(value.rounded())) %")
    }
}
