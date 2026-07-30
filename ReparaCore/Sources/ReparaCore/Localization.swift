import Foundation

/// Reading the 127 council type names in either language.
///
/// The names themselves are not app strings and are not in the catalogue —
/// they arrive in `taxonomy.json` with a hand-written `en` gloss beside the
/// council's own `descricao`, and are regenerated wholesale from the TypeScript
/// client. See the taxonomy section of CLAUDE.md.
///
/// Foundation only, like the rest of `ReparaCore`: which language a reader wants
/// is a question about a `Locale`, not about a view.
extension Locale {

    /// Does this reader want Portuguese?
    ///
    /// Asked of the language alone, so `pt-BR` counts. The app only ships
    /// European Portuguese — see `AppLanguage.matchingSystem`, which is why a
    /// Brazilian phone gets here at all rather than falling through to English.
    public var prefersPortuguese: Bool {
        language.languageCode == .portuguese
    }
}

extension Bundle {

    /// The `.lproj` inside this bundle that holds a given reader's strings.
    ///
    /// **`String(localized:locale:)` does not do this for you.** Its `locale`
    /// argument governs how the *interpolations* are formatted; the table it
    /// looks the key up in comes from the bundle. This app's language is a
    /// setting rather than the process's language, so the two disagree the
    /// moment somebody overrides it — and the symptom is silent, a screen that
    /// simply stays English. `LanguageTests.actionableErrorsTranslate` is what
    /// caught it.
    ///
    /// Matched on the language prefix, not the exact identifier, because SwiftPM
    /// lowercases `pt-PT.lproj` to `pt-pt.lproj` on the way into the bundle and
    /// an iOS device's filesystem is case-sensitive.
    public func strings(for locale: Locale) -> Bundle {
        let wanted = locale.prefersPortuguese ? "pt" : "en"
        guard
            let name = localizations.first(where: { $0.lowercased().hasPrefix(wanted) }),
            let path = path(forResource: name, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else { return self }
        return bundle
    }
}

extension TipoOcorrencia {

    /// The council's own wording, or the bundled English gloss, by locale.
    ///
    /// **Portuguese is the fallback, not the alternative.** `en` is hand-written
    /// and may be absent; `descricao` is what the council actually calls this
    /// and always exists. So a type nobody has glossed yet shows its real name
    /// rather than an empty row — and the name it shows is the one that appears
    /// on the council's own site, which is the more useful failure.
    public func localizedDescricao(in locale: Locale) -> String {
        let name = locale.prefersPortuguese ? descricao : (en ?? descricao)
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The parent council area, same rule.
    ///
    /// Worth showing next to the name rather than treated as decoration: five
    /// descriptions are worded identically across two areas and route to
    /// different departments, so the area is part of what identifies a type.
    public func localizedArea(in locale: Locale) -> String {
        let name = locale.prefersPortuguese ? area : (areaEn ?? area)
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Is there a second name worth printing under the first?
    ///
    /// Only in an English app, and only when a gloss exists. In a Portuguese
    /// app there is one name — the council's — and repeating an English
    /// translation of it under every row is noise on a screen that already asks
    /// the reader to tell 127 similar things apart.
    private func hasBothNames(in locale: Locale) -> Bool {
        guard !locale.prefersPortuguese, let en, !en.isEmpty else { return false }
        return en != descricao
    }

    /// The English gloss, for screens that keep the **Portuguese primary**.
    ///
    /// That is `ReviewView`, and only `ReviewView`: it is the screen that says
    /// *this is what is being sent*, and the type is what routes the report to a
    /// department, so the council's own wording stays the headline in either
    /// language and the translation sits under it.
    public func englishGloss(in locale: Locale) -> String? {
        guard hasBothNames(in: locale) else { return nil }
        return en?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The council's own wording, for screens that keep the **reader's language
    /// primary** — browsing and the type picker.
    ///
    /// Nobody browsing is standing in the street about to file, so there the
    /// useful headline is the one they can read; but the Portuguese still
    /// belongs underneath, because it is what the type is called on the
    /// council's own site and in the report that eventually gets filed.
    public func alternateDescricao(in locale: Locale) -> String? {
        guard hasBothNames(in: locale) else { return nil }
        return descricao.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The council's own name for the parent area, on the same terms.
    ///
    /// Gated on the *area* having a gloss rather than the type having one, so a
    /// section header does not disappear because one type in it is untranslated.
    public func alternateArea(in locale: Locale) -> String? {
        guard !locale.prefersPortuguese, let areaEn, !areaEn.isEmpty, areaEn != area else {
            return nil
        }
        return area.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
