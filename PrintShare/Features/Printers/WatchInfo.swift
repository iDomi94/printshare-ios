import SwiftUI

/// AI failure detection on a printer card (server 0.23.0): a small status line while it watches, a red box with the
/// checked camera frame on an alert - "false alarm" mutes it for the rest of the print, "pause" stops the printer.
struct WatchInfo: View {
    let printer: String
    let watch: WatchState
    var busy: String
    var onMute: () -> Void
    var onPause: () -> Void

    @Environment(AppModel.self) private var app

    /// The status line, nil while idle (and on an alert, which gets the box instead).
    static func line(_ t: L10n, _ w: WatchState) -> String? {
        if let e = w.error, !e.isEmpty { return t(.watchError, ["error": e]) }
        switch w.state {
        case .idle, .alert: return nil
        case .warming: return t(.watchWarming)
        case .muted: return t(.watchMuted)
        case .watching: return t(.watchActive)
        }
    }

    var body: some View {
        let t = app.l10n
        if watch.state == .alert {
            VStack(alignment: .leading, spacing: 10) {
                Label(t(.watchAlert), systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(Theme.danger)
                Text(watch.paused ? t(.watchPaused) : t(.watchCheck)).font(.subheadline).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if watch.frame {
                    let path = "/api/printers/\(printer.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? printer)"
                        + "/watch/frame?t=\(Int(watch.lastCheck ?? 0))"
                    Color.clear.aspectRatio(4 / 3, contentMode: .fit)
                        .overlay { RemoteImage(url: path) }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                }
                HStack(spacing: 10) {
                    PSButton(title: t(.watchFalseAlarm), kind: .secondary, icon: "checkmark",
                             loading: busy == "\(printer):mute", action: onMute)
                    if !watch.paused {
                        PSButton(title: t(.pause), kind: .danger, icon: "pause.fill",
                                 loading: busy == "\(printer):pause", action: onPause)
                    }
                }
            }
            .padding(12)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.danger, lineWidth: 2))
            .padding(.top, 14)
        } else if let text = Self.line(t, watch) {
            Label(text, systemImage: watch.error != nil ? "exclamationmark.circle" : "eye")
                .font(.footnote).foregroundStyle(watch.error != nil ? Theme.danger : Theme.sub)
                .lineLimit(2)
                .padding(.top, 12)
        }
    }
}
