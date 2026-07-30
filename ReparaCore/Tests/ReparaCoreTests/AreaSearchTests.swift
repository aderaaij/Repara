import Foundation
import Testing

@testable import ReparaCore

/// The app API answers "what is reported around here, of any type" — the one
/// question the web API cannot be asked without spending 127 requests.
///
/// Its two counter-intuitive properties are what these tests pin: it reports
/// failure with HTTP 200, and it carries a street address that must not be
/// decoded.
@Suite("Area search")
struct AreaSearchTests {

    /// Modelled on a live response: the exact field set the server sends, with
    /// the wording and JSON types it really uses, and synthetic values.
    ///
    /// Coordinates are **numbers**, not strings — the Android model types them
    /// as strings and the wire disagrees. The state wording is the server's
    /// ("Em análise"), not the Android client's display labels ("Análise").
    /// The identifying fields are present on purpose, so the decoder is asked
    /// to drop them rather than merely not offered them.
    ///
    /// The resolved row is invented: a live 450 m call returned 451 rows and
    /// not one `RS`. It is here to prove the filter works, not because the
    /// server is expected to send one.
    private static let populated = """
        {"data":{"ocos":[
          {"id":1,"num":"OCO/00001/2000","desc":"Passeio levantado",
           "tipo":"Passeios","tipoId":262,
           "area":"Passeios e Acessibilidades","areaId":5,"freg":"Santa Maria Maior",
           "est":"Em análise","estId":"AN",
           "lat":38.70754,"lon":-9.13647,"dist":12.5,
           "criadoPorMim":false,"aSerSeguida":false,
           "resp_url":"https://example.invalid/crest.png",
           "local":"Rua Secreta 14, 1100-000 Lisboa",
           "fotos":[{"url":"https://example.invalid/1.jpg"}]},
          {"id":2,"num":"OCO/00002/2000","desc":"Já resolvido",
           "tipo":"Higiene","tipoId":54,"area":"Higiene Urbana","areaId":10,
           "freg":"Santa Maria Maior","est":"Resolvida","estId":"RS",
           "lat":38.70760,"lon":-9.13650,"dist":30.0,
           "local":"Rua Secreta 16, 1100-000 Lisboa"}
        ]}}
        """

    /// Decodes through the real envelope, not a convenience shape. An earlier
    /// version of these tests unwrapped `ocos` from the root and passed against
    /// a decoder that could never have read a live response.
    private func decode(_ json: String) throws -> [AreaOccurrence] {
        try JSONDecoder()
            .decode(AreaSearch.Response.self, from: Data(json.utf8))
            .data?.ocos ?? []
    }

    // MARK: Privacy

    /// The same rule `NearByOccurrence` is held to: the address has no storage
    /// to be dropped from, so it cannot reach a log, a cache or a model prompt.
    @Test("the street address is never decoded")
    func addressNotDecoded() throws {
        let found = try decode(Self.populated)
        let mirrored = found.flatMap { Mirror(reflecting: $0).children.compactMap(\.label) }

        #expect(!mirrored.contains("local"))
        #expect(!mirrored.contains("fotos"))

        // And nothing that did survive carries the address text.
        let serialised = String(describing: found)
        #expect(!serialised.contains("Rua Secreta"))
        #expect(!serialised.contains("1100-000"))
    }

    // MARK: Coordinates

    /// The app API takes and returns WGS84, so the portal's 114 m datum shift
    /// cannot reach this path. If someone routes these through `Projection`,
    /// the coordinates land in the Atlantic and this test says so.
    @Test("coordinates are WGS84, whether sent as numbers or strings")
    func coordinatesAreDegrees() throws {
        let decoded = try decode(Self.populated)
        let first = try #require(decoded.first)

        #expect(abs(first.lat - 38.70754) < 1e-6)
        #expect(abs(first.lon - -9.13647) < 1e-6)
        // Praça do Comércio, give or take a block.
        #expect(abs(first.coordinate.lat - Projection.reference.wgs84.lat) < 0.01)
        #expect(abs(first.coordinate.lng - Projection.reference.wgs84.lng) < 0.01)
    }

    /// The server sends numbers; the Android model says strings. Both have to
    /// work, because a coordinate that quietly became NaN puts a pin in the
    /// Atlantic rather than throwing.
    @Test("a coordinate sent as a string still decodes")
    func coordinatesAsStrings() throws {
        let found = try decode(
            #"{"data":{"ocos":[{"id":5,"est":"Em análise","estId":"AN","lat":"38.70754","lon":"-9.13647"}]}}"#)
        let one = try #require(found.first)
        #expect(abs(one.lat - 38.70754) < 1e-6)
        #expect(abs(one.lon - -9.13647) < 1e-6)
        #expect(!one.lat.isNaN && !one.lon.isNaN)
    }

    // MARK: Resolved reports

    @Test("resolved reports are recognised by code and by wording")
    func resolvedDetected() throws {
        let found = try decode(Self.populated)
        #expect(found.count == 2)
        #expect(found[0].isResolved == false)
        #expect(found[1].isResolved == true)
    }

    /// A missing `estId` must not make a resolved report look open. The text is
    /// the fallback, accents and all.
    @Test("a resolved report with no code is still resolved")
    func resolvedByTextAlone() throws {
        let found = try decode(
            #"{"data":{"ocos":[{"id":3,"est":"Resolvida","lat":"38.7","lon":"-9.1"}]}}"#)
        let one = try #require(found.first)
        #expect(one.isResolved)
    }

    @Test("an unknown state reads as open")
    func unknownStateIsOpen() throws {
        let found = try decode(
            #"{"data":{"ocos":[{"id":4,"est":"Qualquer coisa nova","estId":"ZZ","lat":"38.7","lon":"-9.1"}]}}"#)
        let one = try #require(found.first)
        #expect(one.isResolved == false)
    }

    /// The three states a live response actually contained, in the server's own
    /// wording — which is *not* the wording in the Android client's resources.
    /// All three are open work and none may be filtered out.
    @Test("every state the server actually sends reads as open")
    func observedStatesAreOpen() throws {
        for (code, text) in [
            ("AN", "Em análise"),
            ("EX", "Em execução"),
            ("ENC", "Registado para Resolução"),
        ] {
            let found = try decode(
                #"{"data":{"ocos":[{"id":6,"est":"\#(text)","estId":"\#(code)","lat":38.7,"lon":-9.1}]}}"#)
            let one = try #require(found.first, "\(code) should decode")
            #expect(!one.isResolved, "\(code) (\(text)) is open work, not resolved")
        }
    }

    // MARK: Conversion to the shared shape

    /// Browse converts to `NearByOccurrence` so the map, clustering, rows and
    /// sheet stay written against one shape. The conversion projects — and it
    /// must project **our** way, not the portal's.
    @Test("converting to NearByOccurrence projects with our own transform")
    func conversionProjects() throws {
        let found = try decode(Self.populated)
        let source = try #require(found.first)
        let converted = NearByOccurrence(source)

        // Round-tripping through EPSG:3763 and back must land where it started.
        // If anyone routes this through the portal's forward call instead, the
        // result is ~114 m away and this fails.
        let back = converted.coordinate
        #expect(abs(back.lat - source.lat) < 1e-6)
        #expect(abs(back.lng - source.lon) < 1e-6)

        #expect(converted.point.distance(to: Projection.forward(source.coordinate)) < 0.001)
        #expect(converted.id == source.id)
        #expect(converted.numero == source.numero)
        #expect(converted.tipoId == source.tipoId)
        #expect(converted.distance == source.distance)
        #expect(converted.isResolved == source.isResolved)
    }

    /// The resolved/open verdict has to survive the conversion, because the
    /// browse screen sorts open from closed on the converted value and the two
    /// types decide it from differently-named fields.
    @Test("resolved state survives conversion")
    func conversionKeepsResolvedState() throws {
        let found = try decode(Self.populated)
        #expect(found.map { NearByOccurrence($0).isResolved } == [false, true])
    }

    /// Conversion must not smuggle in what decoding refused.
    @Test("conversion carries no address")
    func conversionCarriesNoAddress() throws {
        let converted = try decode(Self.populated).map { NearByOccurrence($0) }
        let serialised = String(describing: converted)
        #expect(!serialised.contains("Rua Secreta"))
        #expect(!serialised.contains("@"))
    }

    // MARK: The envelope

    /// The whole reason `GapEnvelope` exists. A dead session arrives as 200
    /// with an empty body, and must not read as "nothing is reported near you"
    /// — the same all-clear-from-a-failure that `RelatedSearch.failed` prevents
    /// on the web side.
    @Test("an expired session is a failure, not an empty neighbourhood")
    func invalidSessionIsNotEmpty() throws {
        let json = """
            {"gap":{"errorMessage":"Sessão não encontrada","invalidSession":true,
                    "invalidVersion":false,"nextScreen":0,"operationSucceeded":false}}
            """
        let response = try JSONDecoder()
            .decode(AreaSearch.Response.self, from: Data(json.utf8))

        #expect(response.data == nil, "the failure carries no payload at all")
        let gap = try #require(response.gap)
        #expect(gap.operationSucceeded == false)
        #expect(gap.invalidSession)
    }

    /// The bug this decoder actually shipped with, kept as a test because it
    /// fails silently rather than loudly: every app-API payload lives under
    /// `data`, so a decoder reading the root finds nothing, throws nothing, and
    /// renders an empty map over a neighbourhood full of reports.
    ///
    /// The Android client hides this — its request layer unwraps `data` before
    /// handing the body to Gson, so its response entity names `ocos` at what
    /// looks like the top level. Reading the entity alone misleads.
    @Test("occurrences at the root are not read — the payload is under data")
    func rootLevelPayloadIsIgnored() throws {
        let atRoot = #"{"ocos":[{"id":9,"est":"Análise","lat":"38.7","lon":"-9.1"}]}"#
        #expect(try decode(atRoot).isEmpty)

        let wrapped = #"{"data":{"ocos":[{"id":9,"est":"Análise","lat":"38.7","lon":"-9.1"}]}}"#
        #expect(try decode(wrapped).count == 1)
    }

    /// Populated responses omit the envelope entirely, so absence must mean
    /// success — otherwise every good answer throws.
    @Test("a missing envelope is success")
    func missingEnvelopeIsSuccess() throws {
        let gap = try JSONDecoder().decode(GapEnvelope.self, from: Data("{}".utf8))
        #expect(gap.operationSucceeded)
        #expect(!gap.invalidSession)
    }

    // MARK: The request

    /// `raio` is a request against a municipal server, not a display choice.
    /// The Android client's own slider stops at 450 and so does this.
    @Test("the radius is capped at what the portal is known to be asked for")
    func radiusCapped() {
        #expect(AreaSearch.maxRadiusMetres == 450)
        #expect(AreaSearch.defaultRadiusMetres == 225)
        #expect(AreaSearch.defaultRadiusMetres <= AreaSearch.maxRadiusMetres)
    }

    /// The app context is a different servlet context from the web one. If
    /// these ever collapse onto the same base, the submission path and the
    /// browse path stop being distinguishable.
    @Test("the app API is a different context from the web API")
    func contextsAreDistinct() {
        #expect(AppPortal.apiBase != Portal.apiBase)
        #expect(AppPortal.apiBase.hasPrefix("https://"))
        #expect(AppPortal.apiBase.hasSuffix("/naminharuav2-app"))
        #expect(AppPortal.publicBase.hasSuffix("/publico-app"))
    }

    /// The app authenticates with a header, not the `JSESSIONID` cookie, and
    /// the token has to actually reach it.
    @Test("the GAP header carries the token")
    func gapHeaderCarriesToken() throws {
        let header = try #require(AppPortal.gapHeader(authToken: "tok-123")["GAP"])
        #expect(header.contains("\"authToken\":\"tok-123\""))
        #expect(header.contains("\"so\":\"ios\""))

        let anonymous = try #require(AppPortal.gapHeader()["GAP"])
        #expect(anonymous.contains("\"authToken\":\"\""))
    }
}
