import UIKit

@MainActor
enum Haptics {
    /// Light tap, used by every button (`tap()` in the Expo app).
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
