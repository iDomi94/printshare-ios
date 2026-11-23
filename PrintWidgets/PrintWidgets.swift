import ActivityKit
import AppIntents
import SwiftUI
import UIKit
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
                    ActivityPicture(job: context.attributes.job, printer: context.attributes.printer, state: state,
                                    size: 52)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(WidgetText.percent(state)).font(.caption.monospacedDigit().bold())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(WidgetText.printer(context.attributes.printer)).font(.caption.bold()).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: state.progress).tint(WidgetText.tint(state))
                        HStack {
                            Text(WidgetText.status(state)).font(.caption)
                            Spacer()
                            RemainingText(state: state).font(.caption.monospacedDigit())
                        }
                        HStack {
                            TemperatureText(state: state).font(.caption2.monospacedDigit())
                            Spacer()
                            CameraButton(job: context.attributes.job, printer: context.attributes.printer, state: state)
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
        HStack(alignment: .center, spacing: 12) {
            ActivityPicture(job: attributes.job, printer: attributes.printer, state: state, size: 76)
            VStack(alignment: .leading, spacing: 6) {
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
                    if let l = state.l, let lt = state.lt, lt > 0, !state.heating {
                        Text(WidgetText.t("layer", ["n": String(l), "total": String(lt)])).font(.caption)
                    }
                    RemainingText(state: state).font(.subheadline.monospacedDigit())
                }
                .foregroundStyle(.secondary)
                if state.hasTemperatures || !state.isOver {
                    HStack {
                        TemperatureText(state: state).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        CameraButton(job: attributes.job, printer: attributes.printer, state: state)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
    }
}

/// The print up to the current layer (rendered by the app), or the last camera picture with its time. Tapping it opens
/// the live camera in the app.
private struct ActivityPicture: View {
    let job: String
    let printer: String
    let state: PrintActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        if let pick = ActivityImages.pick(job: job, state: state) {
            Link(destination: WidgetText.cameraURL(printer)) {
                switch pick {
                case .frame(let url):
                    picture(url, fill: false)
                case .camera(let url, let at):
                    picture(url, fill: true)
                        .overlay(alignment: .bottom) {
                            Text(at, style: .time).font(.system(size: 9).monospacedDigit())
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.black.opacity(0.6)).clipShape(Capsule()).padding(3)
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func picture(_ url: URL, fill: Bool) -> some View {
        if let img = UIImage(contentsOfFile: url.path) {
            Image(uiImage: img).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
                .frame(width: size, height: size)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// "Düse 215/220° · Bett 60/60° · Kammer 31°"
private struct TemperatureText: View {
    let state: PrintActivityAttributes.ContentState

    var body: some View {
        Text(WidgetText.temperatures(state)).lineLimit(1).minimumScaleFactor(0.8)
    }
}

/// Loads a fresh camera picture through the app (in the background, without opening it).
private struct CameraButton: View {
    let job: String
    let printer: String
    let state: PrintActivityAttributes.ContentState

    var body: some View {
        if !state.isOver && ActivityImages.mode != .none {
            Button(intent: RefreshCameraIntent(job: job, printer: printer)) {
                Image(systemName: "camera.fill").font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.white.opacity(0.18)).clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(WidgetText.t("cameraRefresh"))
        }
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
        "heating": ("Heizt auf", "Heating up"),
        "nozzle": ("Düse", "Nozzle"),
        "bed": ("Bett", "Bed"),
        "chamber": ("Kammer", "Chamber"),
        "cameraRefresh": ("Kamerabild aktualisieren", "Refresh camera picture"),
    ]

    static func t(_ key: String, _ args: [String: String] = [:]) -> String {
        guard let pair = texts[key] else { return key }
        var s = PushShared.lang == "de" ? pair.de : pair.en
        for (k, v) in args { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
        return s
    }

    static func status(_ s: PrintActivityAttributes.ContentState) -> String { t(s.heating ? "heating" : s.s) }

    static func temperatures(_ s: PrintActivityAttributes.ContentState) -> String {
        func one(_ key: String, _ actual: Int?, _ target: Int?) -> String? {
            guard let actual else { return nil }
            if let target, target > 0 { return "\(t(key)) \(actual)/\(target)°" }
            return "\(t(key)) \(actual)°"
        }
        return [one("nozzle", s.tn, s.tnt), one("bed", s.tb, s.tbt), one("chamber", s.tc, nil)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    static func cameraURL(_ printer: String) -> URL {
        var c = URLComponents()
        c.scheme = "printshare"
        c.host = "camera"
        c.queryItems = [URLQueryItem(name: "printer", value: printer)]
        return c.url ?? URL(string: "printshare://camera")!
    }
    static func printer(_ id: String) -> String { PushShared.printerName(id) ?? t("printer") }
    static func percent(_ s: PrintActivityAttributes.ContentState) -> String { s.s == "done" ? "100 %" : "\(s.p ?? 0) %" }

    static func icon(_ s: PrintActivityAttributes.ContentState) -> String {
        switch s.s {
        case "done": return "checkmark.circle.fill"
        case "paused", "decision": return "pause.circle.fill"
        case "error", "failed", "cancelled": return "exclamationmark.triangle.fill"
        case "waking": return "power"
        case "printing" where s.heating: return "flame.fill"
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
