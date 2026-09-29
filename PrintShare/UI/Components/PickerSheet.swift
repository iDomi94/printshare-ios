import SwiftUI

struct Choice: Identifiable, Hashable {
    var value: String
    var label: String
    var group: String?
    var sub: String?
    var id: String { value }
}

/// Sheet with a searchable, optionally grouped list (materials, quality, plates …).
struct PickerSheet: View {
    var title: String
    var choices: [Choice]
    var selected: String?
    var searchLabel: String
    var closeLabel: String
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var groups: [(title: String, items: [Choice])] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        var order: [String] = []
        var map: [String: [Choice]] = [:]
        for c in choices {
            if !needle.isEmpty && !"\(c.label) \(c.group ?? "")".lowercased().contains(needle) { continue }
            let g = c.group ?? ""
            if map[g] == nil { order.append(g); map[g] = [] }
            map[g]?.append(c)
        }
        return order.map { (title: $0, items: map[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            list
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button(closeLabel) { dismiss() } }
                }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var list: some View {
        let content = List {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        Button {
                            Haptics.tap()
                            onPick(item.value)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.label).foregroundStyle(Theme.text)
                                    if let sub = item.sub { Text(sub).font(.footnote).foregroundStyle(Theme.sub) }
                                }
                                Spacer()
                                if item.value == selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                        .accessibilityAddTraits(item.value == selected ? .isSelected : [])
                    }
                }
            }
        }
        if choices.count > 8 {
            content.searchable(text: $query, prompt: searchLabel)
        } else {
            content
        }
    }
}
