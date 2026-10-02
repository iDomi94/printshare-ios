import SwiftUI

/// A Spoolman booking the user has to decide (print cancelled or its end missed): book all, the printed share or nothing.
struct BookingCard: View {
    let booking: Booking
    var onDone: () -> Void

    @Environment(AppModel.self) private var app
    @State private var busy: Double?
    @State private var error = ""

    static func grams(_ v: Double) -> String { String(format: "%.1f", (v * 10).rounded() / 10) }

    /// "Spoolman: 11.4 g booked on #3 Elegoo PLA"
    static func bookedText(_ t: L10n, _ b: Booking) -> String {
        t(.booked, ["g": grams(b.grams), "spool": b.uses.map(\.label).joined(separator: ", ")])
    }

    var body: some View {
        let t = app.l10n
        let part = booking.ask?.part ?? 1
        let total = booking.grams
        PSCard(padding: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(t(.bookingAsk, ["file": booking.file, "printer": booking.printerName]))
                    .font(.subheadline).foregroundStyle(Theme.text)
                Text(booking.uses.map { "\(Self.grams($0.grams)) g → \($0.label)" }.joined(separator: "\n"))
                    .font(.footnote).foregroundStyle(Theme.sub)
                if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
                VStack(spacing: 8) {
                    PSButton(title: t(.bookAll, ["g": Self.grams(total)]), loading: busy == 1, disabled: busy != nil) {
                        decide(1)
                    }
                    if part > 0.01 && part < 0.99 {
                        PSButton(title: t(.bookPart, ["g": Self.grams(total * part), "pct": String(Int((part * 100).rounded()))]),
                                 kind: .secondary, loading: busy == part, disabled: busy != nil) { decide(part) }
                    }
                    PSButton(title: t(.bookNone), kind: .plain, loading: busy == 0, disabled: busy != nil) { decide(0) }
                }
                .padding(.top, 6)
            }
        }
        .padding(.bottom, 16)
    }

    private func decide(_ part: Double) {
        busy = part
        error = ""
        Task {
            defer { busy = nil }
            do {
                try await app.resolveBooking(booking.id, part: part)
                onDone()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
