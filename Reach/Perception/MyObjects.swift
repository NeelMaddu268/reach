import Foundation

/// "This is my mug": reference photos of the user's own things, kept across launches, so "find my mug" can pick
/// theirs out of similar ones.
enum MyObjects {
    /// Saves a reference photo for `label`, replacing any earlier one.
    static func save(_ jpeg: Data, as label: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try jpeg.write(to: folder.appendingPathComponent(ElevenLabs.slug(label) + ".jpg"))
    }

    /// Saves the label text read from the reference photo (medication check).
    static func saveText(_ text: String, as label: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appendingPathComponent(ElevenLabs.slug(label) + ".txt"), atomically: true, encoding: .utf8)
    }

    /// The reference photo for whatever `query` names ("mug" finds "my mug"), if there is one.
    static func reference(for query: String) -> Data? {
        file(for: query, extension: "jpg").flatMap { try? Data(contentsOf: $0) }
    }

    /// The saved label text for `query`, only if it was saved under that name (never another medicine's label).
    static func text(for query: String) -> String? {
        file(for: query, extension: "txt", exact: true).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// The one saved under `query` itself (plural or not) wins, so "mug" never gets "travel mug". `exact`: only that one.
    private static func file(for query: String, extension ext: String, exact: Bool = false) -> URL? {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == ext }
        let name = { (file: URL) in file.deletingPathExtension().lastPathComponent }
        let wanted = ElevenLabs.slug(query)
        if let own = files.first(where: { name($0) == wanted || name($0) + "s" == wanted || name($0) == wanted + "s" }) {
            return own
        }
        guard !exact else { return nil }
        return files.first { AppModel.matches(name($0).replacingOccurrences(of: "-", with: " "), query) }
    }

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyObjects")
    }
}
