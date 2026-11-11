import ActivityKit
import SwiftUI
import WidgetKit

@main
struct PrintWidgets: WidgetBundle {
    var body: some Widget {
        PrintActivityWidget()
    }
}

/// A running print on the lock screen and in the Dynamic Island (server 0.51.0). The server updates it through the
/// push relay; names come from the App Group because the relay only carries ids and numbers.
struct PrintActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PrintActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state, stale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(WidgetText.jobURL(context.attributes.job))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(WidgetText.printer(context.attributes.printer), systemImage: "printer.fill")
                        .font(.caption).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(WidgetText.percent(state)).font(.caption.monospacedDigit().bold())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: state.progress).tint(WidgetText.tint(state))
                        HStack {
                            Text(WidgetText.status(state)).font(.caption)
                            Spacer()
                            RemainingText(state: state).font(.caption.monospacedDigit())
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: WidgetText.icon(state)).foregroundStyle(WidgetText.tint(state))
            } compactTrailing: {
                Text(WidgetText.percent(state)).font(.caption2.monospacedDigit())
            } minimal: {
                ProgressView(value: state.progress) {
                    Image(systemName: WidgetText.icon(state))
                }
                .progressViewStyle(.circular).tint(WidgetText.tint(state))
            }
            .widgetURL(WidgetText.jobURL(context.attributes.job))
        }
    }
}

private struct LockScreenView: View {
    let attributes: PrintActivityAttributes
    let state: PrintActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: WidgetText.icon(state)).foregroundStyle(WidgetText.tint(state))
                Text(WidgetText.printer(attributes.printer)).font(.headline).lineLimit(1)
                Spacer()
                Text(WidgetText.percent(state)).font(.headline.monospacedDigit())
            }
            ProgressView(value: state.progress).tint(WidgetText.tint(state))
            HStack {
                Text(stale ? WidgetText.t("stale") : WidgetText.status(state)).font(.subheadline)
                Spacer()
                if let l = state.l, let lt = state.lt, lt > 0 {
                    Text(WidgetText.t("layer", ["n": String(l), "total": String(lt)])).font(.caption)
                }
                RemainingText(state: state).font(.subheadline.monospacedDigit())
            }
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

/// "noch 1:12:05" counting down by itself (no push needed for it) and "fertig ca. 16:40".
private struct RemainingText: View {
    let state: PrintActivityAttributes.ContentState

    var body: some View {
        if state.s == "printing", let end = state.endDate, end > Date() {
            Text(timerInterval: Date()...end, countsDown: true)
        }
    }
}

/// The few texts the widget needs, in the app's language (the widget has no access to the app's L10n).
enum WidgetText {
    private static let texts: [String: (de: String, en: String)] = [
        "sending": ("Wird gesendet …", "Sending …"),
        "waking": ("Drucker wird eingeschaltet …", "Switching the printer on …"),
        "decision": ("Wartet auf dich – App öffnen", "Waiting for you – open the app"),
        "printing": ("Druckt", "Printing"),
        "paused": ("Pausiert", "Paused"),
        "done": ("Fertig", "Finished"),
        "cancelled": ("Abgebrochen", "Cancelled"),
        "error": ("Druckerfehler", "Printer error"),
        "failed": ("Nicht gestartet", "Not started"),
        "stale": ("Kein aktueller Stand", "No current status"),
        "layer": ("Schicht {n}/{total}", "Layer {n}/{total}"),
        "printer": ("Drucker", "Printer"),
    ]

    static func t(_ key: String, _ args: [String: String] = [:]) -> String {
        guard let pair = texts[key] else { return key }
        var s = PushShared.lang == "de" ? pair.de : pair.en
        for (k, v) in args { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
        return s
    }

    static func status(_ s: PrintActivityAttributes.ContentState) -> String { t(s.s) }
    static func printer(_ id: String) -> String { PushShared.printerName(id) ?? t("printer") }
    static func percent(_ s: PrintActivityAttributes.ContentState) -> String { s.s == "done" ? "100 %" : "\(s.p ?? 0) %" }

    static func icon(_ s: PrintActivityAttributes.ContentState) -> String {
        switch s.s {
        case "done": return "checkmark.circle.fill"
        case "paused", "decision": return "pause.circle.fill"
        case "error", "failed", "cancelled": return "exclamationmark.triangle.fill"
        case "waking": return "power"
        default: return "printer.fill"
        }
    }

    static func tint(_ s: PrintActivityAttributes.ContentState) -> Color {
        switch s.s {
        case "done": return .green
        case "paused", "decision": return .yellow
        case "error", "failed", "cancelled": return .red
        default: return .orange
        }
    }

    static func jobURL(_ job: String) -> URL? {
        var c = URLComponents()
        c.scheme = "printshare"
        c.host = "job"
        c.queryItems = [URLQueryItem(name: "id", value: job)]
        return c.url
    }
}
