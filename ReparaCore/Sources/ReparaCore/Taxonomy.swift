import Foundation

public enum TaxonomyError: Error, CustomStringConvertible {
    case noMatch(query: String, total: Int)
    case ambiguous(query: String, candidates: [TipoOcorrencia])
    case bundleMissing

    public var description: String {
        switch self {
        case let .noMatch(query, total):
            return """
                Nothing matches "\(query)". Browse the \(total) report types instead — \
                search works in English too.
                """
        case let .ambiguous(query, candidates):
            let list = candidates.prefix(10)
                .map { "  \($0.id)  \($0.descricao) — \($0.area)" }
                .joined(separator: "\n")
            let more =
                candidates.count > 10 ? "\n  …and \(candidates.count - 10) more" : ""
            return """
                "\(query)" matches \(candidates.count) report types, which route to \
                different council departments. Pick one:
                \(list)\(more)
                """
        case .bundleMissing:
            return "taxonomy.json is missing from the app bundle. This is a build error."
        }
    }
}

/// The 127 occurrence types across 12 areas, bundled rather than fetched.
///
/// Fetching costs 13 requests and 711 KB (the areas payload inlines base64 PNG
/// icons), for data that changes about as often as municipal departments
/// reorganise. Regenerate from the TypeScript repo with:
///
///     npm run nmr -- types --json > taxonomy.json
public struct Taxonomy: Sendable {
    public let types: [TipoOcorrencia]

    /// Type id → the ids of every type worded *identically* to it in another
    /// area. Built once at init, because `related(to:)` is read from a view body.
    ///
    /// These are the five descriptions `resolve` already has to disambiguate
    /// with a `--<area>` slug suffix. Same wording and a different department is
    /// the definition of a confusable pair, so the sibling map gets them for
    /// free and stays correct when `taxonomy.json` is regenerated — no hand
    /// curation to fall out of step.
    let collisions: [Int: [Int]]

    public init(types: [TipoOcorrencia]) {
        self.types = types

        var byWording: [String: [Int]] = [:]
        for type in types { byWording[slugify(type.descricao), default: []].append(type.id) }
        var collisions: [Int: [Int]] = [:]
        for (_, ids) in byWording where ids.count > 1 {
            for id in ids { collisions[id] = ids.filter { $0 != id } }
        }
        self.collisions = collisions
    }

    /// The bundled taxonomy. Loaded once; a missing or malformed resource is a
    /// build error, not a runtime condition worth recovering from.
    public static let bundled: Taxonomy = {
        guard let url = Bundle.module.url(forResource: "taxonomy", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let types = try? JSONDecoder().decode([TipoOcorrencia].self, from: data)
        else {
            assertionFailure("taxonomy.json missing or malformed in ReparaCore's bundle")
            return Taxonomy(types: [])
        }
        return Taxonomy(types: types)
    }()

    /// Areas, derived from the types rather than stored separately.
    public var areas: [AreaOcorrencia] {
        var seen = Set<Int>()
        var out: [AreaOcorrencia] = []
        for type in types where seen.insert(type.areaOcorrenciaId).inserted {
            out.append(AreaOcorrencia(id: type.areaOcorrenciaId, descricao: type.area))
        }
        return out.sorted { $0.descricao.localizedCaseInsensitiveCompare($1.descricao) == .orderedAscending }
    }

    public func types(inArea areaId: Int) -> [TipoOcorrencia] {
        types.filter { $0.areaOcorrenciaId == areaId }
    }

    public func type(id: Int) -> TipoOcorrencia? {
        types.first { $0.id == id }
    }

    /// Free-text search over Portuguese and English alike, so "pothole" works
    /// as well as "buraco" for someone who does not read Portuguese.
    public func search(_ query: String) -> [TipoOcorrencia] {
        let needle = slugify(query)
        guard !needle.isEmpty else { return types }
        return types.filter { $0.matches(needle) }
    }

    /// Resolve free text to exactly one type.
    ///
    /// Accepts a numeric id, an exact slug, or a unique substring. **An
    /// ambiguous substring is an error listing the candidates, never a silent
    /// pick** — five subcategories share wording across areas and route to
    /// different departments, so guessing sends the report to the wrong desk.
    public func resolve(_ query: String) throws -> TipoOcorrencia {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if let id = Int(trimmed) {
            guard let match = type(id: id) else {
                throw TaxonomyError.noMatch(query: trimmed, total: types.count)
            }
            return match
        }

        // Match the raw slug before slugifying, because `slugify` collapses
        // runs of separators and would destroy the `--` that disambiguates the
        // five descriptions duplicated across areas. Without this, the very
        // slugs generated to resolve a collision are themselves unresolvable.
        let lowered = trimmed.lowercased()
        if let exact = types.first(where: { $0.slug == lowered }) { return exact }

        let needle = slugify(trimmed)

        // A description that collides across areas must not resolve on its
        // plain form: the first type keeps the unsuffixed slug and the rest get
        // `--<area>`, so slugifying the shared wording would hand back whichever
        // loaded first. Reaching a collided type means naming its full slug,
        // which the raw match above already handles.
        let sameWording = types.filter { slugify($0.descricao) == needle }
        if sameWording.count > 1 {
            throw TaxonomyError.ambiguous(query: trimmed, candidates: sameWording)
        }

        if let exact = types.first(where: { $0.slug == needle }) { return exact }

        let partial = types.filter { $0.matches(needle) }
        switch partial.count {
        case 1: return partial[0]
        case 0: throw TaxonomyError.noMatch(query: trimmed, total: types.count)
        default: throw TaxonomyError.ambiguous(query: trimmed, candidates: partial)
        }
    }
}

extension TipoOcorrencia {
    fileprivate func matches(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        // The `--` in a disambiguated slug survives here but not in a slugified
        // query, so compare against the collapsed form too — typing one dash or
        // two should both find the type.
        let collapsed = slug.replacingOccurrences(of: "--", with: "-")
        return slug.contains(needle) || collapsed.contains(needle)
            || slugify(descricao).contains(needle) || slugify(en ?? "").contains(needle)
    }
}

/// A stable, typeable handle for an occurrence type.
///
/// "Sacos ou outros lixos abandonados" → "sacos-ou-outros-lixos-abandonados".
/// Diacritics are folded so searching works from a keyboard without a
/// Portuguese layout.
public func slugify(_ text: String) -> String {
    let folded = text.folding(
        options: [.diacriticInsensitive, .caseInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
    )
    var out = ""
    var pendingSeparator = false
    for character in folded.unicodeScalars {
        if CharacterSet.alphanumerics.contains(character), character.isASCII {
            if pendingSeparator, !out.isEmpty { out.append("-") }
            pendingSeparator = false
            out.unicodeScalars.append(character)
        } else {
            pendingSeparator = true
        }
    }
    return out.lowercased()
}
