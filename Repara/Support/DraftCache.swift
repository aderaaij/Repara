import CryptoKit
import Foundation
import ReparaCore

/// Re-use the draft for a photograph that has already been drafted, so that
/// testing the four screens *after* the model call does not re-buy the model
/// call each time the same photo comes back out of the library.
///
/// **Off in a real report, on purpose.** Somebody who starts over and picks the
/// same photograph again is asking for a *different* answer; handing them the
/// previous one back would be the opposite of what they asked for. So this is
/// compiled out of release builds and inert unless `--reuse-drafts` is on the
/// command line — the same shape as `ScreenshotMode`, and for the same reason.
///
/// Written to the caches directory rather than held in memory, because the
/// relaunch after a rebuild is exactly the moment the saved call is worth most.
enum DraftCache {

    // MARK: Activation

    static let isEnabled: Bool = {
        #if DEBUG
            return ProcessInfo.processInfo.arguments.contains("--reuse-drafts")
        #else
            return false
        #endif
    }()

    // MARK: Key

    /// Everything that would change the answer: the bytes the model is shown,
    /// what the person said, and which model on which provider is being asked.
    ///
    /// The photograph is hashed, never stored. Photos carry GPS EXIF and often
    /// show somebody's front door; nothing this writes to disk can be turned
    /// back into one. `nil` when disabled, so the hash is not computed at all
    /// on a normal run.
    static func key(
        photo: Data,
        userText: String,
        provider: ModelProviderID,
        model: String,
        replyLanguage: String
    ) -> String? {
        guard isEnabled else { return nil }
        var hash = SHA256()
        hash.update(data: photo)
        // The language is part of the key, not incidental to it: `notesForUser`
        // comes back in whichever language was asked for, so a draft cached in
        // English is the wrong answer once the app is in Portuguese.
        hash.update(
            data: Data(
                "\u{0}\(userText)\u{0}\(provider.rawValue)\u{0}\(model)\u{0}\(replyLanguage)"
                    .utf8))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Store

    /// The type is kept as its id and resolved against the bundled taxonomy on
    /// the way back out, exactly as `Drafter.parse` does — a cached draft gets
    /// the same "is this a type that exists" check as a fresh one, so a stale
    /// entry cannot outlive a regenerated `taxonomy.json`.
    private struct Stored: Codable {
        var tipoID: Int
        var descricao: String
        var confidence: Drafter.Draft.Confidence
        var notesForUser: String?
    }

    static func draft(forKey key: String?, taxonomy: Taxonomy) -> Drafter.Draft? {
        guard let key, let url = url(for: key),
            let data = try? Data(contentsOf: url),
            let stored = try? JSONDecoder().decode(Stored.self, from: data),
            let type = taxonomy.type(id: stored.tipoID)
        else { return nil }

        return Drafter.Draft(
            type: type,
            descricao: stored.descricao,
            confidence: stored.confidence,
            notesForUser: stored.notesForUser
        )
    }

    static func store(_ draft: Drafter.Draft, forKey key: String?) {
        guard let key, let url = url(for: key) else { return }
        let stored = Stored(
            tipoID: draft.type.id,
            descricao: draft.descricao,
            confidence: draft.confidence,
            notesForUser: draft.notesForUser
        )
        try? JSONEncoder().encode(stored).write(to: url)
    }

    private static let directory: URL? = {
        guard isEnabled,
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let url = base.appendingPathComponent("drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func url(for key: String) -> URL? {
        directory?.appendingPathComponent("\(key).json")
    }
}
