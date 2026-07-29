import Foundation

/// Shapes for the `gopiv2/naminharuav2` API.
///
/// Everything here is transcribed from a real captured session, not from
/// documentation — there is none. Fields marked VERIFIED appeared in a
/// submission that returned 201. Treat the rest as best-effort.

// MARK: - Account

public struct Utilizador: Decodable, Sendable, Equatable {
    public let type: String
    public let code: Int
    public let contacto: String
    public let email: String
    public let nome: String
}

// MARK: - Taxonomy

public struct AreaOcorrencia: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let descricao: String
}

/// An occurrence type, plus the slug the app resolves user input against.
public struct TipoOcorrencia: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let areaOcorrenciaId: Int
    public let area: String
    public let descricao: String
    public let slug: String
    /// Hand-written English gloss. Absent if untranslated.
    public let en: String?
    /// Hand-written English gloss of the parent area.
    public let areaEn: String?

    enum CodingKeys: String, CodingKey {
        case id
        case areaOcorrenciaId = "area_ocorrencia_id"
        case area
        case descricao
        case slug
        case en
        case areaEn
    }

    public init(
        id: Int, areaOcorrenciaId: Int, area: String, descricao: String,
        slug: String, en: String? = nil, areaEn: String? = nil
    ) {
        self.id = id
        self.areaOcorrenciaId = areaOcorrenciaId
        self.area = area
        self.descricao = descricao
        self.slug = slug
        self.en = en
        self.areaEn = areaEn
    }

    /// What the picker shows: Portuguese, with the English gloss underneath.
    public var displayName: String { descricao.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Address resolution

/// One address candidate from `getGeoAttributes` → `morada[]`.
///
/// The server returns two different shapes depending on what the point hits,
/// distinguished by `idtipo` (the same codes the address search filters on with
/// `tipo:2,3,1005,8`):
///
/// - `idtipo: "2"` — a BUILDING. Carries `morada` ("Rua X, 210") and `cod_sig`.
///   This is the shape the verified submission used.
/// - `idtipo: "8"` — a STREET, returned when the point falls on the roadway or
///   pavement rather than on a building footprint. Carries `designacao` (the
///   street name, no house number) and `cod_via` instead. No `morada`, no
///   `cod_sig`.
///
/// Every field is therefore optional; use `label` rather than reaching for
/// `morada` directly.
public struct Morada: Decodable, Sendable, Equatable {
    public let idtipo: String?
    /// Building match: full address including house number.
    public let morada: String?
    /// Building match: SIG identifier.
    public let codSig: String?
    /// Street match: street name, no house number.
    public let designacao: String?
    /// Street match: street identifier.
    public let codVia: String?

    enum CodingKeys: String, CodingKey {
        case idtipo
        case morada
        case codSig = "cod_sig"
        case designacao
        case codVia = "cod_via"
    }

    public init(
        idtipo: String? = nil, morada: String? = nil, codSig: String? = nil,
        designacao: String? = nil, codVia: String? = nil
    ) {
        self.idtipo = idtipo
        self.morada = morada
        self.codSig = codSig
        self.designacao = designacao
        self.codVia = codVia
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The portal is inconsistent about whether these codes arrive as JSON
        // strings or numbers, so accept either rather than failing to resolve
        // an address over a type quibble.
        idtipo = try c.decodeLenientStringIfPresent(.idtipo)
        morada = try c.decodeIfPresent(String.self, forKey: .morada)
        codSig = try c.decodeLenientStringIfPresent(.codSig)
        designacao = try c.decodeIfPresent(String.self, forKey: .designacao)
        codVia = try c.decodeLenientStringIfPresent(.codVia)
    }

    /// True when the point resolved to a street rather than a building footprint.
    public var isStreetMatch: Bool {
        idtipo == "8" || (codVia != nil && morada == nil)
    }

    /// The human-readable address, whichever shape came back. Nil if neither.
    public var label: String? {
        morada ?? designacao
    }
}

/// `getGeoAttributes` response.
///
/// `morada` and `nearBy` are arrays — an earlier API reference in the
/// TypeScript repo flattened both to single objects, which is wrong.
public struct GeoAttributes: Decodable, Sendable {
    public let morada: [Morada]
    public let freguesia: String
    public let freguesiaNome: String
    public let pfm: String
    public let uit: String
    public let evene: String
    public let codLocal: String
    public let nearBy: [NearByOccurrence]

    enum CodingKeys: String, CodingKey {
        case morada
        case freguesia
        case freguesiaNome = "freguesia_nome"
        case pfm = "PFM"
        case uit = "UIT"
        case evene = "EVENE"
        case codLocal = "COD_LOCAL"
        case nearBy
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        morada = try c.decodeIfPresent([Morada].self, forKey: .morada) ?? []
        freguesia = try c.decodeLenientStringIfPresent(.freguesia) ?? ""
        freguesiaNome = try c.decodeIfPresent(String.self, forKey: .freguesiaNome) ?? ""
        pfm = try c.decodeLenientStringIfPresent(.pfm) ?? ""
        uit = try c.decodeLenientStringIfPresent(.uit) ?? ""
        evene = try c.decodeLenientStringIfPresent(.evene) ?? ""
        codLocal = try c.decodeLenientStringIfPresent(.codLocal) ?? ""
        nearBy = try c.decodeIfPresent([NearByOccurrence].self, forKey: .nearBy) ?? []
    }
}

// MARK: - Nearby occurrences (the privacy boundary)

/// A nearby occurrence, reduced to the fields duplicate detection actually needs.
///
/// **This type is the privacy boundary.** The raw server entries carry the full
/// name and email of whoever filed each nearby report. None of that is needed
/// for anything this app does, so it is dropped here — by decoding only the
/// listed keys, which makes retaining the rest structurally impossible rather
/// than merely discouraged. Nothing upstream ever holds the raw shape, so there
/// is no raw shape to leak into a log, a cache, or a Claude prompt.
///
/// See `PrivacyTests`, which asserts that no `@` survives.
public struct NearByOccurrence: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let numero: String
    public let descricao: String?
    public let referencia: String?
    public let tipo: String
    public let tipoId: Int
    public let area: String
    public let areaOcorrenciaId: Int
    public let freguesia: String
    public let estado: String
    public let x: Double
    public let y: Double

    /// Metres from the query point. Filled in by `stripped(relativeTo:)`.
    public private(set) var distance: Double = .nan

    public var point: PtTm06 { PtTm06(x: x, y: y) }
    public var coordinate: LatLng { Projection.inverse(point) }

    /// Deliberately NOT `requerente`, `email`, `criador_id`, `logedUser` or
    /// `local`. Adding a key here re-opens the leak; do not.
    enum CodingKeys: String, CodingKey {
        case id
        case numero
        case descricao
        case referencia
        case tipo
        case tipoId = "tipo_id"
        case area
        case areaOcorrenciaId = "area_oco_id"
        case freguesia = "freg_descricao"
        case estado = "naminharua_estado"
        case state
        case geoX = "geo_x"
        case geoY = "geo_y"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        numero = try c.decodeLenientStringIfPresent(.numero) ?? ""
        descricao = try c.decodeIfPresent(String.self, forKey: .descricao)
        referencia = try c.decodeIfPresent(String.self, forKey: .referencia)
        tipo = try c.decodeIfPresent(String.self, forKey: .tipo) ?? ""
        tipoId = try c.decodeIfPresent(Int.self, forKey: .tipoId) ?? 0
        area = try c.decodeIfPresent(String.self, forKey: .area) ?? ""
        areaOcorrenciaId = try c.decodeIfPresent(Int.self, forKey: .areaOcorrenciaId) ?? 0
        freguesia = try c.decodeIfPresent(String.self, forKey: .freguesia) ?? ""
        estado =
            try c.decodeIfPresent(String.self, forKey: .estado)
            ?? c.decodeIfPresent(String.self, forKey: .state) ?? ""
        x = try c.decodeIfPresent(Double.self, forKey: .geoX) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .geoY) ?? 0
    }

    /// True when the estado reads as already dealt with, so it is not a
    /// duplicate worth warning about.
    public var isResolved: Bool {
        estado.range(of: "resolvid", options: .caseInsensitive) != nil
    }

    /// The only representation of a neighbour that may be sent to the Claude
    /// API. Built from this type's fields, which by construction contain no
    /// reporter identity — see `PrivacyTests.modelFacingSummary`.
    public var promptSummary: String {
        let metres = distance.isFinite ? "\(Int(distance.rounded())) m away" : "nearby"
        let text = descricao?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "- \(tipo) (\(estado), \(metres))\(text.isEmpty ? "" : ": \(text)")"
    }

    func withDistance(from origin: PtTm06) -> NearByOccurrence {
        var copy = self
        copy.distance = point.distance(to: origin)
        return copy
    }
}

extension Array where Element == NearByOccurrence {
    /// Attach distances and sort nearest-first.
    public func stripped(relativeTo origin: PtTm06) -> [NearByOccurrence] {
        map { $0.withDistance(from: origin) }.sorted { $0.distance < $1.distance }
    }
}

// MARK: - Submission payload

/// The `geo` block of a submission. Field order matches the verified capture;
/// see `SubmitObj` for why the wire order is nonetheless not load-bearing.
public struct SubmitGeo: Codable, Sendable, Equatable {
    public var freguesiaId: Int
    public var pfm: String
    public var uit: String
    public var estruturante: String
    /// Sent EMPTY on purpose. The real value rides in `codSigOriginal`. VERIFIED quirk.
    public var codSig: String
    /// Sent EMPTY on purpose. The real value rides in `idtipoOriginal`. VERIFIED quirk.
    public var idTipo: String
    public var morada: String
    /// House number split off the end of `morada`, leading space included.
    public var nPol: String
    public var lon: Double
    public var lat: Double
    public var x: Double
    public var y: Double
    public var freguesiaNome: String
    public var codSigOriginal: String
    public var idtipoOriginal: String
    public var codLocal: String

    enum CodingKeys: String, CodingKey {
        case freguesiaId = "freguesia_id"
        case pfm
        case uit
        case estruturante
        case codSig = "cod_sig"
        case idTipo = "id_tipo"
        case morada
        case nPol = "n_pol"
        case lon
        case lat
        case x = "X"
        case y = "Y"
        case freguesiaNome = "freguesia_nome"
        case codSigOriginal = "cod_sig_original"
        case idtipoOriginal = "idtipo_original"
        case codLocal = "cod_local"
    }
}

/// The `obj` part of the multipart submission.
///
/// Encoded with `JSONEncoder(.sortedKeys)`, so the bytes are identical run to
/// run and a dry-run payload can be diffed. The key order therefore differs
/// from the captured browser submission, which is safe: JSON objects are
/// unordered by specification and the portal's Jersey backend deserialises into
/// a POJO. The quirks that *are* load-bearing — the empty `cod_sig`/`id_tipo`,
/// the `_original` fields, `n_pol`'s leading space, and lat/lon being the
/// inverse projection of the snapped point — are all in the values, not the
/// ordering.
public struct SubmitObj: Codable, Sendable, Equatable {
    public var tipoOcorrenciaId: Int
    public var descricao: String
    public var referencia: String
    public var geo: SubmitGeo

    enum CodingKeys: String, CodingKey {
        case tipoOcorrenciaId = "tipo_ocorrencia_id"
        case descricao
        case referencia
        case geo
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct SubmitResult: Decodable, Sendable, Equatable {
    public let id: Int
    public let numero: String
}

/// A row from `/ocorrencias/my`.
public struct MyOccurrence: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let numero: String
    public let descricao: String?
    public let tipo: String
    public let estado: String

    enum CodingKeys: String, CodingKey {
        case id, numero, descricao, tipo, estado
        case naminharuaEstado = "naminharua_estado"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        numero = try c.decodeLenientStringIfPresent(.numero) ?? ""
        descricao = try c.decodeIfPresent(String.self, forKey: .descricao)
        tipo = try c.decodeIfPresent(String.self, forKey: .tipo) ?? ""
        estado =
            try c.decodeIfPresent(String.self, forKey: .naminharuaEstado)
            ?? c.decodeIfPresent(String.self, forKey: .estado) ?? ""
    }
}

// MARK: - Lenient decoding

extension KeyedDecodingContainer {
    /// Decode a value the portal sends as either a JSON string or a number.
    ///
    /// The codes in `morada` in particular arrive both ways depending on the
    /// endpoint. Failing an address resolution over that would be absurd.
    func decodeLenientStringIfPresent(_ key: Key) throws -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) {
            return d == d.rounded() ? String(Int(d)) : String(d)
        }
        return nil
    }
}
