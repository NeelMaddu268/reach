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

    /// The saved label text for whatever `query` names, if there is one.
    static func text(for query: String) -> String? {
        file(for: query, extension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private static func file(for query: String, extension ext: String) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.first { file in
            let label = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
            return file.pathExtension == ext && AppModel.matches(label, query)
        }
    }

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyObjects")
    }
}
