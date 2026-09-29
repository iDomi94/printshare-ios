import Foundation

/// Error with a friendly, translated message; `detail` keeps the server's original text.
struct APIError: Error, LocalizedError, Sendable, Equatable {
    var message: String
    var status: Int = 0
    var detail: String = ""

    var errorDescription: String? { message }
}
