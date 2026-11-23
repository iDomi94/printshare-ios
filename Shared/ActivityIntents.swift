import AppIntents
import Foundation

/// Hooks the app fills in at launch; in the widget extension they stay empty (a `LiveActivityIntent` runs in the app's
/// process, so `perform()` there finds them).
enum ActivityIntentHooks {
    /// Fetch a camera picture for the job's printer into the App Group and redraw the Live Activity.
    nonisolated(unsafe) static var refreshCamera: (@Sendable (_ job: String, _ printer: String) async -> Void)?
}

/// "Kamera aktualisieren" in the Live Activity: iOS starts the app in the background for it, the app loads one camera
/// picture through the server (also away from home) and the activity shows it.
struct RefreshCameraIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Kamerabild aktualisieren"
    static let isDiscoverable = false

    @Parameter(title: "Job") var job: String
    @Parameter(title: "Printer") var printer: String

    init() {}

    init(job: String, printer: String) {
        self.job = job
        self.printer = printer
    }

    func perform() async throws -> some IntentResult {
        await ActivityIntentHooks.refreshCamera?(job, printer)
        return .result()
    }
}
