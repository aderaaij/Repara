import Foundation

// MARK: - The app API

/// The mobile app's API, which is a different context from the web portal's.
///
/// `naminharuav2` (the web API, `Portal.apiBase`) and `naminharuav2-app` are
/// separate servlet contexts of the same webapp, with separate auth and
/// different shapes for the same nouns. The app context was recovered from the
/// published Android client (`pt.cml.naminharualx`); the web one from a captured
/// browser session. **Neither is a superset of the other**, which is why this
/// app talks to both:
///
/// - Only the web API resolves a point to an address. `getGeoAttributes`
///   returns `morada`, `cod_via` and the freguesia that a submission is built
///   from, and the app API has no equivalent — the Android client asks Google
///   for its addresses. So `Geo` stays where it is.
/// - Only the app API answers "what is reported around here, of any type". The
///   web API's `nearBy` is scoped to one `ocoTipo` by construction.
///
/// Nothing here is on the submission path. `Submit` files against the web API
/// on a shape verified by a real 201, and must keep doing so — see the warning
/// on `AreaSearch.occurrences`.
public enum AppPortal {
    public static let apiBase = Portal.appBase + "/naminharuav2-app"
    public static let publicBase = Portal.appBase + "/publico-app"

    /// The app authenticates with a `GAP` request header carrying JSON, not
    /// with `JSESSIONID`. The token comes from `publico-app/utilizador/login`.
    ///
    /// **A web session does not satisfy this API.** Sending a valid, freshly
    /// issued `JSESSIONID` and no token was answered with `invalidSession` —
    /// tested, not assumed. So an account signed into Repara holds two
    /// independent sessions against the same portal: the cookie that
    /// `getGeoAttributes` and `Submit` need, and the token this needs. They
    /// expire on their own schedules and each has to be renewed on its own.
    ///
    /// `so` is the platform and is not optional — the server reads it. `""` is
    /// what the Android client sends before sign-in, and the public endpoints
    /// (`tipologia`, `faqs`) accept it.
    public static func gapHeader(authToken: String = "") -> [String: String] {
        let json = #"{"appVersion":"1.0.0","so":"ios","authToken":"\#(authToken)"}"#
        return ["GAP": json]
    }
}

// MARK: - The envelope

/// The app API's answer to "did that work", which is **not** the status code.
///
/// Every `-app` response is 200, including the failures. An expired token comes
/// back as 200 with `operationSucceeded: false` and `invalidSession: true`, so
/// code that trusts the status reads an auth failure as an empty result — a
/// dead session would look exactly like "nothing reported near you", which is
/// the same all-clear-from-a-failure that `RelatedSearch.failed` exists to
/// prevent on the web side.
///
/// `AreaSearch` throws on this rather than returning empty, for that reason.
public struct GapEnvelope: Decodable, Sendable {
    public let operationSucceeded: Bool
    public let invalidSession: Bool
    public let invalidVersion: Bool
    public let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case operationSucceeded, invalidSession, invalidVersion, errorMessage
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Absent flags are treated as success: the populated responses omit
        // them, and only the failures spell them out.
        operationSucceeded = try c.decodeIfPresent(Bool.self, forKey: .operationSucceeded) ?? true
        invalidSession = try c.decodeIfPresent(Bool.self, forKey: .invalidSession) ?? false
        invalidVersion = try c.decodeIfPresent(Bool.self, forKey: .invalidVersion) ?? false
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}

// MARK: - One reported problem, from the area search

/// A report near a point, of whatever type — the app API's occurrence shape.
///
/// Kept separate from `NearByOccurrence` rather than merged with it: they come
/// from different APIs with different field names, and the resolved/open rule
/// that `duplicateCandidates` depends on is decided here by `estado`, not by
/// the web API's `naminharua_estado`. Collapsing them would mean one decoder
/// guessing which portal it was talking to.
///
/// **This decodes coordinates as WGS84.** The app API takes and returns
/// `lat`/`lon` directly, so `Projection` is not involved on this path at all —
/// the portal's 114 m datum shift cannot reach it.
///
/// Like `NearByOccurrence`, the key list is the privacy boundary: the response
/// also carries `local`, a street address, and it is deliberately not decoded.
/// Adding a key here re-opens that; do not.
public struct AreaOccurrence: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let numero: String
    public let descricao: String?
    public let tipo: String
    public let tipoId: Int
    public let area: String
    public let areaId: Int
    public let freguesia: String
    /// The state as the portal words it — "Em análise", "Em execução",
    /// "Registado para Resolução".
    ///
    /// Not the same strings the Android client ships in its own resources
    /// ("Análise", "Registada para Resolução"): those are its display labels,
    /// not the server's wording. Match on `estadoId`, never on this.
    public let estado: String
    /// The state as a code: `AN`, `ENC`, `EX` — and in principle `RS`, though
    /// see `AreaSearch.occurrences`: the server does not appear to return
    /// resolved reports here at all.
    public let estadoId: String
    public let lat: Double
    public let lon: Double
    /// Metres from the query point, as the server measured it.
    public let distance: Double

    public var coordinate: LatLng { LatLng(lat: lat, lng: lon) }

    /// Whether the council has marked this done.
    ///
    /// `RS` is the code; the text is checked too because `estId` is a string
    /// field in a response we have not seen populated, and reading a resolved
    /// report as open is the safer of the two mistakes — it shows a greyed pin
    /// instead of hiding a real one.
    public var isResolved: Bool {
        estadoId.uppercased() == "RS"
            || estado.folding(options: .diacriticInsensitive, locale: nil)
                .lowercased().hasPrefix("resolvid")
    }

    /// Deliberately NOT `local` — that is the street address, present on every
    /// row, and the same leak `NearByOccurrence` exists to close. Nor `fotos`:
    /// the photographs are of somebody's street and often their door, and
    /// nothing on the map screen needs them.
    ///
    /// `criadoPorMim`, `aSerSeguida` and `resp_url` are also returned and also
    /// not decoded — the first two are per-account flags this app has no
    /// feature for, the third is a freguesia crest.
    ///
    /// The Android model additionally names `ref`, `responsavel` and
    /// `fotos_res`. **This endpoint returns none of them** — 0 of 451 rows in a
    /// live response — so they are not modelled here. They may exist on the
    /// per-occurrence detail call, which is a different shape.
    enum CodingKeys: String, CodingKey {
        case id, num, desc, tipo, tipoId, area, areaId, freg
        case est, estId, lat, lon, dist
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        numero = try c.decodeLenientStringIfPresent(.num) ?? ""
        descricao = try c.decodeIfPresent(String.self, forKey: .desc)
        tipo = try c.decodeIfPresent(String.self, forKey: .tipo) ?? ""
        tipoId = try c.decodeIfPresent(Int.self, forKey: .tipoId) ?? 0
        area = try c.decodeIfPresent(String.self, forKey: .area) ?? ""
        areaId = try c.decodeIfPresent(Int.self, forKey: .areaId) ?? 0
        freguesia = try c.decodeIfPresent(String.self, forKey: .freg) ?? ""
        estado = try c.decodeIfPresent(String.self, forKey: .est) ?? ""
        estadoId = try c.decodeLenientStringIfPresent(.estId) ?? ""
        // The wire sends these as JSON numbers. The Android model types them as
        // strings, so accept both rather than trusting either — a coordinate
        // that silently became NaN puts a pin in the Atlantic.
        lat = try Self.degrees(c, .lat)
        lon = try Self.degrees(c, .lon)
        distance = try c.decodeIfPresent(Double.self, forKey: .dist) ?? .nan
    }

    private static func degrees(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) throws -> Double {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try c.decodeLenientStringIfPresent(key), let d = Double(s) { return d }
        return .nan
    }
}

// MARK: - The search

/// "What is reported around me, of any type" — the one call the web API cannot
/// make.
///
/// This is the whole reason the app context is worth talking to. The web API
/// answers only about the `ocoTipo` asked for, so the same question there costs
/// 127 requests against a municipal server; here it costs one, and `areas` is
/// a list precisely so it need not be repeated per category.
public enum AreaSearch {

    /// What the Android client caps its own radius slider at. Not a server
    /// limit — the server's is unknown — but the largest value the portal is
    /// known to be asked for, and so the largest this app asks for too.
    public static let maxRadiusMetres = 450

    /// The Android client's default.
    public static let defaultRadiusMetres = 225

    /// Reports near a point, every category at once.
    ///
    /// - Parameters:
    ///   - areaIds: `areas_ocorrencia` ids to restrict to. **Empty means all**,
    ///     which is the normal case and still costs one request.
    ///
    /// **The server returns only open reports.** A live 450 m call answered
    /// with 451 occurrences across 6 areas and 54 types, every one of them
    /// `AN`, `EX` or `ENC` and not a single `RS` — around a square that has
    /// certainly had something fixed in it. So this endpoint is already the
    /// "active occurrences" question, which is what the council's own app shows.
    ///
    /// The `RS` filter below is therefore belt-and-braces, not the mechanism,
    /// and there is deliberately no `includeResolved:` parameter — asking for
    /// resolved reports here does not appear to be possible, and a parameter
    /// that silently cannot do what it says is worse than no parameter. The
    /// greyed resolved pins on the review map still come from `Geo.nearBy`.
    ///
    /// > Warning: The filter query and **filing a report** are the same URL on
    /// > this API, separated only by content type: JSON here, `multipart` with
    /// > an `obj` part there. A `multipart` body sent to this path dispatches a
    /// > council worker. Nothing in this file may build one, and the submission
    /// > path stays on the web API where the payload is verified.
    public static func occurrences(
        _ client: PortalClient,
        near coordinate: LatLng,
        radiusMetres: Int = defaultRadiusMetres,
        areaIds: [Int] = [],
        authToken: String
    ) async throws -> [AreaOccurrence] {
        let filter = Filter(
            centerLat: coordinate.lat,
            centerLon: coordinate.lng,
            raio: String(min(radiusMetres, maxRadiusMetres)),
            areas: areaIds.map(String.init),
            ordem: "distancia"
        )
        let body = try JSONEncoder().encode(filter)

        let response = try await client.json(
            Response.self,
            from: AppPortal.apiBase + "/ocorrencias/",
            method: "POST",
            body: .raw(body, contentType: "application/json"),
            headers: AppPortal.gapHeader(authToken: authToken),
            absolute: true
        )

        // 200 is not success here. An expired token must not read as an
        // empty neighbourhood.
        if let gap = response.gap, !gap.operationSucceeded {
            if gap.invalidSession {
                throw PortalError.notAuthenticated(status: 200, path: "/ocorrencias/ (app)")
            }
            // `errorMessage` is whatever went wrong, unsanitised — a failed
            // login answers with the raw Postgres text. Fine in a developer's
            // log; do not put it in front of somebody standing in the street.
            throw PortalError.unexpectedShape(
                gap.errorMessage ?? "The portal refused the area search",
                path: "/ocorrencias/ (app)")
        }

        return (response.data?.ocos ?? []).filter { !$0.isResolved }
    }

    /// The same call, taking the token from `AppSession` and re-acquiring it
    /// once if the server has expired it.
    ///
    /// This is the overload screens should use. The `authToken:` one exists for
    /// tests and for callers that already hold a token.
    public static func occurrences(
        _ client: PortalClient,
        session: AppSession,
        near coordinate: LatLng,
        radiusMetres: Int = defaultRadiusMetres,
        areaIds: [Int] = []
    ) async throws -> [AreaOccurrence] {
        try await session.withToken { token in
            try await occurrences(
                client, near: coordinate, radiusMetres: radiusMetres,
                areaIds: areaIds, authToken: token)
        }
    }

    /// The request body. `numero`, `estado` and `ambito` are omitted rather
    /// than sent empty — `ambito` in particular means "mine"/"followed" and
    /// narrows the answer to the signed-in user's own reports.
    private struct Filter: Encodable {
        let centerLat: Double
        let centerLon: Double
        let raio: String
        let areas: [String]
        let ordem: String
    }

    /// The app API's envelope: the payload is always under `data`, the outcome
    /// always under `gap`, and **nothing useful is ever at the top level**.
    /// Reading `ocos` from the root — which is where the Android client's
    /// response entity appears to put it, because its request layer unwraps
    /// `data` before deserialising — silently yields no occurrences ever.
    struct Response: Decodable {
        let data: Payload?
        let gap: GapEnvelope?

        struct Payload: Decodable {
            let ocos: [AreaOccurrence]?
        }
    }
}
