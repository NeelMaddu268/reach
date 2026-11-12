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

    /// Whether label text is saved under a name like `query` ("lisinopril" for "lisinopril 10 mg"), exact or not.
    static func hasText(like query: String) -> Bool {
        file(for: query, extension: "txt") != nil
    }

    /// The one saved under `query` itself (plural or not, on any word: "pastillas para la presión") wins, so "mug" never
    /// gets "travel mug". `exact`: only that one.
    private static func file(for query: String, extension ext: String, exact: Bool = false) -> URL? {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == ext }
        let name = { (file: URL) in file.deletingPathExtension().lastPathComponent }
        let words = { (slug: String) in slug.split(separator: "-").map { $0.hasSuffix("s") && !$0.hasSuffix("ss") ? $0.dropLast() : $0 } }
        let wanted = ElevenLabs.slug(query)
        if let own = files.first(where: { name($0) == wanted }) ?? files.first(where: { words(name($0)) == words(wanted) }) {
            return own
        }
        guard !exact else { return nil }
        return files.first { AppModel.matches(name($0).replacingOccurrences(of: "-", with: " "), query) }
    }

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyObjects")
    }
}
