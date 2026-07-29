import Foundation

/// A point resolved to everything a submission needs.
public struct ResolvedLocation: Sendable {
    public let point: PtTm06
    /// The **snapped** coordinate — the inverse projection of `point`, which is
    /// what the submission carries, not the caller's original fix.
    public let coordinate: LatLng
    public let morada: Morada
    public let geo: SubmitGeo
    public let nearBy: [NearByOccurrence]

    /// True when the point hit a street rather than a building. The resulting
    /// payload has no house number and carries `cod_via` where a building would
    /// carry `cod_sig` — a shape no captured submission has ever exercised.
    public let isStreetMatch: Bool

    public var address: String { geo.morada }
    public var freguesia: String { geo.freguesiaNome }

    /// Set when the user should be told something before submitting.
    public var warning: String? {
        guard isStreetMatch else { return nil }
        return """
            This pin is on the street, not on a building, so the report will carry no house \
            number. Drag it onto the building frontage to get a numbered address — that is \
            what a council worker navigates by.
            """
    }
}

/// The result of looking under more than one occurrence type at once.
///
/// `failed` is not bookkeeping. This whole mechanism exists to tell somebody
/// "that mattress is already booked for collection", and the inverse claim —
/// "nothing is booked here, go ahead and file" — is only honest if the lookup
/// actually happened. A caller that ignores `failed` will eventually tell
/// somebody the coast is clear because the network was down.
public struct RelatedSearch: Sendable {
    /// Everything found, deduplicated by occurrence id and nearest-first.
    public let found: [NearByOccurrence]
    /// The type ids that answered.
    public let searched: [Int]
    /// The type ids that did not. Nothing is known about these.
    public let failed: [Int]

    public init(found: [NearByOccurrence], searched: [Int], failed: [Int]) {
        self.found = found
        self.searched = searched
        self.failed = failed
    }

    /// True when every type asked for answered, so an empty `found` genuinely
    /// means nothing is there.
    public var isComplete: Bool { failed.isEmpty }

    public var isEmpty: Bool { found.isEmpty }
}

public enum Geo {

    /// How far out `nearBy` reaches, near enough.
    ///
    /// The portal documents nothing; this is measured off a captured response,
    /// where 89 entries ran from 3 m to 99 m from the query point. It exists so
    /// the browse screen can say what area it just covered — **never to filter
    /// with.** The server's real radius is its own business and may not be a
    /// circle at all.
    public static let nearByRadiusMetres = 100.0

    /// `GET /ocorrencias/getGeoAttributes/` — resolves a point to the municipal
    /// attributes a submission needs, with the nearby reports already stripped
    /// of reporter identity.
    public static func attributes(
        _ client: PortalClient,
        at point: PtTm06,
        tipoId: Int
    ) async throws -> GeoAttributes {
        try await client.json(
            GeoAttributes.self,
            from: "/ocorrencias/getGeoAttributes/",
            query: ["x": String(point.x), "y": String(point.y), "ocoTipo": String(tipoId)]
        )
    }

    /// What the portal already has of one type around a point — the browse call.
    ///
    /// The same request `resolve` makes, without the submission built from it.
    /// Two differences carry the whole browse screen:
    ///
    /// - **No address is needed.** `resolve` throws when a point has no
    ///   `morada`; looking at what has been reported in a park or along a river
    ///   bank should still answer.
    /// - **One type per call.** A captured answer for `ocoTipo=262` returned 89
    ///   entries and every one of them was type 262, so the server filters by
    ///   the type asked for. There is no "everything reported here" request:
    ///   that would be 127 of these, at a municipal service, per look.
    ///
    /// Costs the portal exactly one request, and files nothing — browsing is
    /// the one thing in this app that cannot dispatch anybody. Reporter identity
    /// is dropped on the way in by `NearByOccurrence`, as everywhere else; see
    /// `PrivacyTests`.
    public static func nearBy(
        _ client: PortalClient,
        around coordinate: LatLng,
        tipoId: Int
    ) async throws -> [NearByOccurrence] {
        // Distances and map pins are only as honest as the projection, and a
        // 114 m drift is exactly the failure this app exists to avoid.
        try Projection.verify()

        let point = Projection.forward(coordinate)
        return try await attributes(client, at: point, tipoId: tipoId)
            .nearBy
            .stripped(relativeTo: point)
    }

    /// What the portal has around a point under **several** types.
    ///
    /// The server answers for one `ocoTipo` at a time, so this is one request
    /// per type and there is no way to make it fewer. That is the entire cost of
    /// cross-type duplicate detection, and why `Taxonomy.maxRelatedLookups`
    /// caps the caller at three: see `Taxonomy.related(to:)`.
    ///
    /// Requests go **one at a time**, not concurrently. Three simultaneous
    /// connections to a municipal server to save a second of somebody's time is
    /// not a trade this app makes.
    ///
    /// A type that fails does not take the others down with it. The distinction
    /// matters to the caller: "nothing is booked here" and "we could not find
    /// out" must not look the same, or a failed lookup reads as an all-clear.
    public static func nearBy(
        _ client: PortalClient,
        around coordinate: LatLng,
        tipoIds: [Int]
    ) async throws -> RelatedSearch {
        try Projection.verify()
        let point = Projection.forward(coordinate)

        var found: [NearByOccurrence] = []
        var searched: [Int] = []
        var failed: [Int] = []

        for tipoId in tipoIds {
            do {
                found += try await attributes(client, at: point, tipoId: tipoId).nearBy
                searched.append(tipoId)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed.append(tipoId)
            }
        }

        // Deduplicated by occurrence id: a report cannot be two occurrences, and
        // nothing guarantees the server never returns one under two types.
        var seen = Set<Int>()
        let unique = found.filter { seen.insert($0.id).inserted }

        return RelatedSearch(
            found: unique.stripped(relativeTo: point),
            searched: searched,
            failed: failed
        )
    }

    /// Turn a raw coordinate into the full `geo` block of a submission.
    ///
    /// This is the whole point of the app: the portal makes you place a pin on a
    /// map that centres 114 m from where you are, and this does it from a GPS
    /// fix — or from wherever the user has dragged the pin to.
    public static func resolve(
        _ client: PortalClient,
        at coordinate: LatLng,
        tipoId: Int
    ) async throws -> ResolvedLocation {
        try Projection.verify()

        let point = Projection.forward(coordinate)
        let attrs = try await attributes(client, at: point, tipoId: tipoId)

        guard let morada = attrs.morada.first, let label = morada.label else {
            throw PortalError.noAddressFound(
                at: coordinate, point: point, insideLisbon: Projection.isInLisbon(point))
        }
        guard let freguesiaId = Int(attrs.freguesia) else {
            throw PortalError.unexpectedShape(
                "getGeoAttributes returned freguesia \"\(attrs.freguesia)\", which is not a "
                    + "number. Refusing to build a submission from it.",
                path: "/ocorrencias/getGeoAttributes/")
        }

        let isStreetMatch = morada.isStreetMatch

        // The lat/lon submitted are the inverse projection of the *snapped*
        // point, not the caller's original coordinates — matching the portal.
        let snapped = Projection.inverse(point)

        let geo = SubmitGeo(
            freguesiaId: freguesiaId,
            pfm: attrs.pfm,
            uit: attrs.uit,
            estruturante: attrs.evene,
            // Sent empty on purpose; the real values ride in *_original.
            codSig: "",
            idTipo: "",
            morada: label,
            // A street match has no house number to split off.
            nPol: isStreetMatch ? "" : splitHouseNumber(label),
            lon: snapped.lng,
            lat: snapped.lat,
            x: point.x,
            y: point.y,
            freguesiaNome: attrs.freguesiaNome,
            // Buildings identify by cod_sig, streets by cod_via.
            codSigOriginal: morada.codSig ?? morada.codVia ?? "",
            idtipoOriginal: morada.idtipo ?? "",
            codLocal: attrs.codLocal
        )

        return ResolvedLocation(
            point: point,
            coordinate: snapped,
            morada: morada,
            geo: geo,
            nearBy: attrs.nearBy.stripped(relativeTo: point),
            isStreetMatch: isStreetMatch
        )
    }
}

/// Split the house number off the end of a `morada`.
///
/// The verified capture sent a morada of the form "Rua Exemplo, 210" with
/// `n_pol` `" 210"` — the tail after the last comma, **leading space intact**,
/// and the morada left whole. Reproduced verbatim rather than trimmed.
///
/// Guarded so that an address whose tail is not a house number (a place name,
/// say) yields `""` instead of pushing a word into a number field.
public func splitHouseNumber(_ morada: String) -> String {
    guard let comma = morada.lastIndex(of: ",") else { return "" }
    let tail = String(morada[morada.index(after: comma)...])

    let trimmed = tail.drop { $0.isWhitespace }
    guard let first = trimmed.first, first.isNumber else { return "" }

    // Everything after the leading digits may be a letter suffix (12A), a range
    // (12-14), an ordinal (3º) or spacing — but not a word.
    let allowed: Set<Character> = ["-", "/", "º", "°", "."]
    let isHouseNumber = trimmed.allSatisfy { character in
        character.isLetter || character.isNumber || character.isWhitespace
            || allowed.contains(character)
    }
    return isHouseNumber ? tail : ""
}
