import Foundation

private final class WritingGuideAnchor: NSObject {}

public enum WritingGuide {
    public static let humanizerVersion = "2.11.2"
    public static let humanizerSource = "https://github.com/blader/humanizer"
    public static let humanizerLicense = "MIT"

    public static let baseline = """
        Write in plain, direct language suited to the reader. Lead with the useful point. Use concrete verbs, \
        preserve the author's tone and terminology, and cut filler, inflated claims, and formulaic transitions. \
        Keep the source's facts, names, figures, dates, quotations, citations, and uncertainty. Never make up details. \
        Treat the owner's voice notes as style cues only. Return the final wording for review.
        """

    public static let humanizer: String? = {
        let containingBundle = Bundle(for: WritingGuideAnchor.self)
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        let directories = [
            Bundle.main.resourceURL,
            executable?.deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true),
            executable,
            Bundle.main.bundleURL,
            containingBundle.bundleURL.deletingLastPathComponent()
        ].compactMap { $0 }
        return loadHumanizer(in: directories)
    }()

    // SwiftPM's generated Bundle.module traps when its optional bundle is unavailable.
    static func loadHumanizer(in directories: [URL]) -> String? {
        for directory in directories {
            let bundle = directory.appendingPathComponent("Hereforth_HereforthCore.bundle", isDirectory: true)
            guard let resources = Bundle(url: bundle)?.resourceURL else { continue }
            let skill = resources.appendingPathComponent("Humanizer/SKILL.md")
            if let text = try? String(contentsOf: skill, encoding: .utf8), !text.isEmpty { return text }
        }
        return nil
    }
}

extension Store {
    public static let voiceNotesByteLimit = 8_192

    func installVoiceNotesTable() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS owner_voice_notes (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                notes TEXT NOT NULL
            )
            """)
    }

    public func voiceNotes() throws -> String {
        try db.query("SELECT notes FROM owner_voice_notes WHERE id = 1") { Database.string($0, 0) }.first ?? ""
    }

    public func updateVoiceNotes(_ notes: String) throws {
        guard notes.utf8.count <= Self.voiceNotesByteLimit else {
            throw HereforthError("Keep voice notes within 8 KB of plain text.")
        }
        if notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try db.execute("DELETE FROM owner_voice_notes WHERE id = 1")
            return
        }
        guard accepts(notes, limit: Self.voiceNotesByteLimit, multiline: true) else {
            throw HereforthError("Use plain text for voice notes.")
        }
        try db.execute("""
            INSERT INTO owner_voice_notes (id, notes) VALUES (1, ?)
            ON CONFLICT(id) DO UPDATE SET notes = excluded.notes
            """, [notes])
    }
}
