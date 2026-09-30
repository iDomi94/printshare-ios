import Foundation

/// What the share extension hands to the app.
struct SharedItem: Codable, Sendable, Equatable {
    var url: String?
    var text: String?
    /// Path relative to the App Group container (`Inbox/<uuid>/<name>`).
    var file: String?
    var fileName: String?
}

/// Hand-over folder in the App Group container, used by the share extension (writer) and the app (reader).
enum SharedInbox {
    static let groupID = "group.io.github.halvar20000.printshare"
    private static let manifest = "inbox.json"

    static func container(_ override: URL? = nil) -> URL? {
        override ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    /// Copy a file into `Inbox/<uuid>/<name>` and return its relative path.
    static func stage(fileAt source: URL, name: String, in root: URL? = nil) throws -> String {
        guard let base = container(root) else { throw CocoaError(.fileNoSuchFile) }
        let safe = name.isEmpty ? "model.stl" : name
        let rel = "Inbox/\(UUID().uuidString)/\(safe)"
        let target = base.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        return rel
    }

    static func write(_ item: SharedItem, in root: URL? = nil) throws {
        guard let base = container(root) else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(item).write(to: base.appendingPathComponent(manifest), options: .atomic)
    }

    /// The waiting item, without removing it.
    static func peek(in root: URL? = nil) -> SharedItem? {
        guard let base = container(root),
              let data = try? Data(contentsOf: base.appendingPathComponent(manifest)) else { return nil }
        return try? JSONDecoder().decode(SharedItem.self, from: data)
    }

    static func clear(in root: URL? = nil) {
        guard let base = container(root) else { return }
        try? FileManager.default.removeItem(at: base.appendingPathComponent(manifest))
    }

    static func fileURL(_ relative: String, in root: URL? = nil) -> URL? {
        container(root)?.appendingPathComponent(relative)
    }

    /// Delete a staged file (its `Inbox/<uuid>` folder) once the server has it. Files outside the inbox are left alone.
    static func removeStaged(_ file: URL, in root: URL? = nil) {
        guard let inbox = container(root)?.appendingPathComponent("Inbox", isDirectory: true) else { return }
        let folder = file.deletingLastPathComponent().standardizedFileURL
        guard folder.deletingLastPathComponent().path == inbox.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Delete staged files older than `age` (uploads that were abandoned), keeping the one still waiting in the manifest.
    static func purge(olderThan age: TimeInterval = 24 * 3600, now: Date = Date(), in root: URL? = nil) {
        guard let base = container(root) else { return }
        let inbox = base.appendingPathComponent("Inbox", isDirectory: true)
        let waiting = peek(in: root)?.file?.split(separator: "/").dropFirst().first.map(String.init)
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for folder in folders where folder.lastPathComponent != waiting {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if now.timeIntervalSince(created) > age { try? fm.removeItem(at: folder) }
        }
    }
}
