import Foundation
import ReparaCore
import SwiftUI

/// Which language **the app** speaks.
///
/// Not which language the report is written in. Those are two different things
/// and the whole point of this file is that they stay that way: `descricao` is
/// filed in European Portuguese whatever this is set to, because a council
/// worker reads it and acts on it. See `Drafter.systemPrompt`, which hardcodes
/// pt-PT, and `LanguageTests`, which pins that this setting cannot reach it.
///
/// What this does govern is everything around that text — the chrome, the
/// warnings, the type names, and the model's notes to the reporter, which are
/// shown and never filed.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    /// Follow the phone. The default, and what almost everyone will leave it on.
    case system
    case english
    case portuguese

    var id: String { rawValue }

    static let storageKey = "appLanguage"

    static var selected: AppLanguage {
        get {
            UserDefaults.standard.string(forKey: storageKey)
                .flatMap(AppLanguage.init(rawValue:)) ?? .system
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }

    // MARK: Resolution

    /// The locale every view resolves its strings against.
    ///
    /// **This always lands on a language the app actually ships**, so what the
    /// setting says and what the screen shows cannot disagree. Letting an
    /// unshipped locale through would leave iOS to fall back on the development
    /// region silently, which is the same screen by a route nobody can explain.
    var locale: Locale {
        switch self {
        case .system: Self.matchingSystem
        case .english: Self.englishLocale
        case .portuguese: Self.portugueseLocale
        }
    }

    /// Which of the two shipped languages the phone's own settings ask for.
    ///
    /// Deliberately not `Locale.autoupdatingCurrent`: a phone set to Brazilian
    /// Portuguese does not match a `pt-PT` bundle, so it would fall past
    /// Portuguese and land on English — the wrong answer for the many Brazilian
    /// residents of Lisbon this app is for. **Any** Portuguese at the top of the
    /// preference list means Portuguese. The wording they get is European, which
    /// is the council's own register and the one the portal replies in.
    static var matchingSystem: Locale {
        let first = Locale.preferredLanguages.first.map(Locale.init(identifier:))
        return first?.language.languageCode == .portuguese ? portugueseLocale : englishLocale
    }

    /// Portugal pinned, not merely "Portuguese": the app's Portuguese is
    /// European, and a Lisbon address, a distance in metres and a date are all
    /// more readable in the local format than in the reader's home one.
    static let portugueseLocale = Locale(identifier: "pt_PT")

    /// The user's own region kept, unlike Portuguese — an English-reading
    /// resident of Lisbon has a region already set and nothing here is improved
    /// by overriding it. Bundle lookup falls back from `en_PT` to `en`.
    static var englishLocale: Locale {
        Locale(identifier: "en_\(Locale.current.region?.identifier ?? "PT")")
    }

    /// How to name the reader's language **to a model**.
    ///
    /// Used only for the fields the reporter reads and nobody files —
    /// `notes_for_user` and the duplicate judge's `reason`. The report body is
    /// not one of them and must never be: it is European Portuguese because a
    /// council worker reads it, whatever language the app is in. See
    /// `Drafter.systemPrompt`, which states that unconditionally, and
    /// `LanguageTests`.
    static func promptName(for locale: Locale) -> String {
        locale.prefersPortuguese ? "European Portuguese" : "English"
    }

    /// The bundle language, which is a different thing from the environment
    /// locale and has to be set separately.
    ///
    /// `\.locale` governs everything **this app** draws, and it takes effect the
    /// moment the picker closes. It does not govern what **iOS** draws on the
    /// app's behalf: the camera and location permission alerts are system UI and
    /// read the bundle's preferred localisation, so without this a Portuguese
    /// app would ask for the camera in English. Writing `AppleLanguages` is what
    /// makes those match — from the next launch, by which time the in-app text
    /// changed long ago.
    ///
    /// `.system` **removes** the key rather than writing a language into it, so
    /// "follow the phone" goes on following the phone instead of freezing
    /// whichever language it happened to be on the day it was chosen.
    func syncBundleLanguage() {
        let key = "AppleLanguages"
        switch self {
        case .system: UserDefaults.standard.removeObject(forKey: key)
        case .english: UserDefaults.standard.set(["en"], forKey: key)
        case .portuguese: UserDefaults.standard.set(["pt-PT"], forKey: key)
        }
    }

    /// Each language named **in itself**, which is why two of these are
    /// deliberately not translatable: somebody who has the app in a language
    /// they cannot read is exactly the person using this picker, and
    /// "Portuguese" is no help to them. `.system` is the exception — it answers
    /// "what happens if I leave this alone" rather than naming a language, so it
    /// is written in whatever the app is currently speaking.
    @ViewBuilder var pickerLabel: some View {
        switch self {
        case .system: Text("System")
        case .english: Text(verbatim: "English")
        case .portuguese: Text(verbatim: "Português")
        }
    }
}

// MARK: - Root

/// Applies the chosen language to everything below it.
///
/// A wrapper rather than a modifier applied in `ReparaApp` because `@AppStorage`
/// has to be read by a `View` for the switch to redraw the app. Changing the
/// setting re-renders every screen in place, with no relaunch — which is the
/// half of the job `AppleLanguages` cannot do. `syncBundleLanguage` does the
/// other half, for the alerts iOS draws rather than this app.
struct LocalizedRoot<Content: View>: View {
    @AppStorage(AppLanguage.storageKey) private var stored = AppLanguage.system.rawValue

    @ViewBuilder var content: Content

    private var language: AppLanguage {
        AppLanguage(rawValue: stored) ?? .system
    }

    var body: some View {
        content
            .environment(\.locale, language.locale)
    }
}

// MARK: - Looking a string up

extension Locale {

    /// The bundle whose string table this reader's language lives in.
    ///
    /// Needed at every `String(localized:)` call site, and easy to leave off
    /// without noticing: the `locale:` argument formats the *interpolations*,
    /// while the table comes from the bundle. Omit this and the screen quietly
    /// stays in whatever language the process launched in — no warning, no
    /// crash, just English. `LanguageTests` is what caught it.
    ///
    /// SwiftUI's `Text("…")` needs none of this; it resolves against
    /// `\.locale` from the environment on its own. This is only for the places
    /// that have to build a `String` before they have a `Text` to put it in.
    var bundle: Bundle { Bundle.main.strings(for: self) }
}
