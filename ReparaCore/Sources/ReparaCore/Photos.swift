import Foundation

/// The photographs on a report — the council's own, not this app's.
///
/// `getGeoAttributes` does not carry them: 34 fields on a nearby occurrence and
/// no `foto` among them. They come from a second call, `/ocorrencias/{id}/fotos`,
/// which is in the portal's own resource definitions (`api-reference.json`) and
/// is what `ocoDetail.html` renders as "Fotos antes" and "Fotos depois" — before
/// and after the council attended. Hence `fase`: the phase asked for. Omitted
/// here, which appears to answer with everything.
///
/// **Unverified in a way the rest of this client is not.** The captured session
/// never called it, so the path is the portal's but the response shape is not
/// something anybody has seen. `parse` is therefore deliberately tolerant — it
/// takes an array of strings, an array of objects with a URL-ish field, or
/// either of those wrapped in an envelope — and returns nothing rather than
/// throwing when it recognises none of them. A report with no photograph and a
/// shape we cannot read must not look like a network failure.
///
/// One request per report opened, and only when somebody opens one. Never
/// prefetched for a list: eighty-nine reports on a corner would be
/// eighty-nine requests at a municipal server for pictures nobody asked to see.
public enum Photos {

    /// `GET /ocorrencias/{id}/fotos` — every photograph on one report.
    ///
    /// Off-origin references are dropped. The portal has no reason to point at
    /// another host, and a client that follows whatever a response tells it to
    /// fetch is a client that can be pointed anywhere.
    public static func urls(_ client: PortalClient, occurrence id: Int) async throws -> [URL] {
        let (data, _) = try await client.request("/ocorrencias/\(id)/fotos")
        return parse(data)
    }

    /// The image bytes, through the session — these need the portal cookie, so
    /// they cannot be handed to an image loader that does not have it.
    ///
    /// Nothing is written to disk. A photograph of somebody's doorway is theirs;
    /// this app shows it while a sheet is open and forgets it.
    public static func image(_ client: PortalClient, at url: URL) async throws -> Data {
        let (data, _) = try await client.request(url.absoluteString, absolute: true)
        return data
    }

    // MARK: Parsing

    static func parse(_ data: Data) -> [URL] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return references(in: json, depth: 0).compactMap(resolve)
    }

    /// Every string in the answer that could be a photograph, in the order found.
    ///
    /// Recursive because the envelope is unknown — `[...]`, `{"fotos": [...]}`
    /// and `{"data": {"fotos": [...]}}` are all shapes this portal uses
    /// elsewhere. Depth-capped so a pathological response cannot walk forever.
    private static func references(in json: Any, depth: Int) -> [String] {
        guard depth < 4 else { return [] }
        switch json {
        case let text as String:
            return looksLikeAPhoto(text) ? [text] : []
        case let list as [Any]:
            return list.flatMap { references(in: $0, depth: depth + 1) }
        case let object as [String: Any]:
            // Named fields first and in a fixed order, so an object carrying
            // both a URL and, say, a caption cannot answer with the caption.
            for key in photoKeys {
                if let text = object[key] as? String, looksLikeAPhoto(text) { return [text] }
            }
            return object.keys.sorted().flatMap {
                references(in: object[$0] ?? "", depth: depth + 1)
            }
        default:
            return []
        }
    }

    private static let photoKeys = ["url", "foto", "src", "path", "href", "imagem", "link"]

    /// A path or an absolute URL, not a caption and not a date.
    private static func looksLikeAPhoto(_ text: String) -> Bool {
        guard text.count > 1, !text.contains(" ") else { return false }
        return text.hasPrefix("/") || text.hasPrefix("http") || text.contains("fotos")
    }

    /// Resolved against the portal, and refused if it leaves it.
    private static func resolve(_ reference: String) -> URL? {
        let url: URL? =
            reference.hasPrefix("http")
            ? URL(string: reference)
            : URL(string: Portal.origin + (reference.hasPrefix("/") ? "" : "/") + reference)

        guard let url, let host = url.host(), let origin = URL(string: Portal.origin)?.host(),
            host == origin
        else { return nil }
        return url
    }
}
