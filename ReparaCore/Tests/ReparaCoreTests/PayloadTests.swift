import Foundation
import Testing

@testable import ReparaCore

/// The submission payload, regenerated and compared against the recorded one.
///
/// Every quirk asserted here is counter-intuitive, undocumented, and was
/// established by capturing a submission the portal answered 201 to. Getting
/// one of them subtly wrong does not fail loudly — it files a plausible-looking
/// report against the wrong thing, and a council worker is dispatched.
@Suite("Submission payload")
struct PayloadTests {

    /// Rebuild the recorded submission from its coordinates and compare field
    /// for field. This is the test the handoff calls for before submit is ever
    /// wired up: if it passes, the app sends what the portal already accepted.
    @Test("regenerates the recorded submission field-for-field")
    func regeneratesRecordedPayload() async throws {
        let recorded = try Fixture.json("submit-payload")
        let recordedGeo = try #require(recorded["geo"] as? [String: Any])

        let (client, _) = try Fixture.client(returning: "geo-attributes-building")
        let report = try await Submitter(client: client).prepare(
            type: .litter,
            at: Projection.reference.wgs84,
            descricao: recorded["descricao"] as! String
        )
        let geo = report.obj.geo

        // Strings must match exactly.
        #expect(report.obj.tipoOcorrenciaId == recorded["tipo_ocorrencia_id"] as! Int)
        #expect(report.obj.descricao == recorded["descricao"] as! String)
        #expect(report.obj.referencia == recorded["referencia"] as! String)
        #expect(geo.freguesiaId == recordedGeo["freguesia_id"] as! Int)
        #expect(geo.pfm == recordedGeo["pfm"] as! String)
        #expect(geo.uit == recordedGeo["uit"] as! String)
        #expect(geo.estruturante == recordedGeo["estruturante"] as! String)
        #expect(geo.codSig == recordedGeo["cod_sig"] as! String)
        #expect(geo.idTipo == recordedGeo["id_tipo"] as! String)
        #expect(geo.morada == recordedGeo["morada"] as! String)
        #expect(geo.nPol == recordedGeo["n_pol"] as! String)
        #expect(geo.freguesiaNome == recordedGeo["freguesia_nome"] as! String)
        #expect(geo.codSigOriginal == recordedGeo["cod_sig_original"] as! String)
        #expect(geo.idtipoOriginal == recordedGeo["idtipo_original"] as! String)
        #expect(geo.codLocal == recordedGeo["cod_local"] as! String)

        // Coordinates round-trip through a different projection implementation
        // than the capture did, so they are compared as distances, not equality.
        let recordedPoint = PtTm06(
            x: recordedGeo["X"] as! Double, y: recordedGeo["Y"] as! Double)
        #expect(PtTm06(x: geo.x, y: geo.y).distance(to: recordedPoint) < 0.001)
        #expect(abs(geo.lat - (recordedGeo["lat"] as! Double)) < 1e-9)
        #expect(abs(geo.lon - (recordedGeo["lon"] as! Double)) < 1e-9)
    }

    /// The wire names are the contract. A Swift rename that silently changed one
    /// would produce a payload the portal quietly ignores parts of.
    @Test("encodes exactly the sixteen geo keys the portal expects")
    func geoWireKeys() async throws {
        let (client, _) = try Fixture.client(returning: "geo-attributes-building")
        let report = try await Submitter(client: client).prepare(
            type: .litter, at: Projection.reference.wgs84, descricao: "x")

        let encoded = try JSONSerialization.jsonObject(with: try report.obj.encoded())
        let obj = try #require(encoded as? [String: Any])
        let geo = try #require(obj["geo"] as? [String: Any])

        #expect(Set(obj.keys) == ["tipo_ocorrencia_id", "descricao", "referencia", "geo"])
        #expect(
            Set(geo.keys) == [
                "freguesia_id", "pfm", "uit", "estruturante", "cod_sig", "id_tipo", "morada",
                "n_pol", "lon", "lat", "X", "Y", "freguesia_nome", "cod_sig_original",
                "idtipo_original", "cod_local",
            ])
    }

    // MARK: The quirks, stated one at a time

    @Test("cod_sig and id_tipo are sent empty, with the real values in *_original")
    func emptyCodSigQuirk() async throws {
        let (client, _) = try Fixture.client(returning: "geo-attributes-building")
        let report = try await Submitter(client: client).prepare(
            type: .litter, at: Projection.reference.wgs84, descricao: "x")

        #expect(report.obj.geo.codSig.isEmpty)
        #expect(report.obj.geo.idTipo.isEmpty)
        #expect(report.obj.geo.codSigOriginal == "1000000000000")
        #expect(report.obj.geo.idtipoOriginal == "2")
    }

    @Test("a street match carries cod_via in cod_sig_original and no house number")
    func streetMatchQuirk() async throws {
        let (client, _) = try Fixture.client(returning: "geo-attributes-street")
        let report = try await Submitter(client: client).prepare(
            type: .litter, at: Projection.reference.wgs84, descricao: "x")

        #expect(report.location.isStreetMatch)
        #expect(report.obj.geo.morada == "Rua Exemplo")
        #expect(report.obj.geo.nPol.isEmpty)
        #expect(report.obj.geo.codSigOriginal == "34311")  // cod_via, not cod_sig
        #expect(report.obj.geo.idtipoOriginal == "8")
        #expect(report.location.warning != nil, "a street match must warn the user")
    }

    @Test("lat/lon are the inverse projection of the snapped point, not the input")
    func snappedCoordinates() async throws {
        // Feed a coordinate a few metres off and check the payload carries the
        // round-tripped value rather than the raw one.
        let raw = LatLng(lat: 38.70760, lng: -9.13650)
        let (client, _) = try Fixture.client(returning: "geo-attributes-building")
        let report = try await Submitter(client: client).prepare(
            type: .litter, at: raw, descricao: "x")

        let expected = Projection.inverse(Projection.forward(raw))
        #expect(abs(report.obj.geo.lat - expected.lat) < 1e-12)
        #expect(abs(report.obj.geo.lon - expected.lng) < 1e-12)
    }

    // MARK: Description limits

    @Test("an empty description is refused")
    func emptyDescription() async throws {
        let (client, _) = try Fixture.client(returning: "geo-attributes-building")
        await #expect(throws: SubmitError.self) {
            _ = try await Submitter(client: client).prepare(
                type: .litter, at: Projection.reference.wgs84, descricao: "   \n ")
        }
    }

    /// The textarea says `maxlength="2048"` but the placeholder says 2000, and
    /// server-side truncation is silent. Enforce the lower number.
    @Test("a description over 2000 characters is refused, not truncated")
    func longDescription() async throws {
        let (client, _) = try Fixture.client(returning: "geo-attributes-building")
        let submitter = Submitter(client: client)

        _ = try await submitter.prepare(
            type: .litter, at: Projection.reference.wgs84,
            descricao: String(repeating: "a", count: 2000))

        await #expect(throws: SubmitError.self) {
            _ = try await submitter.prepare(
                type: .litter, at: Projection.reference.wgs84,
                descricao: String(repeating: "a", count: 2001))
        }
    }

    // MARK: Duplicates

    /// The fixture is the portal's answer for one type, so all three neighbours
    /// are that type — the server never sends another, and a fixture that did
    /// would depict a response nothing has to handle. Each of the two rejects is
    /// therefore rejected for exactly one reason.
    @Test("open reports within 50 m are flagged; too far and already resolved are not")
    func duplicateDetection() async throws {
        let (client, _) = try Fixture.client(returning: "geo-attributes-building")
        let report = try await Submitter(client: client).prepare(
            type: .litter, at: Projection.reference.wgs84, descricao: "x")

        #expect(report.location.nearBy.count == 3)
        #expect(
            report.location.nearBy.allSatisfy { $0.tipoId == TipoOcorrencia.litter.id },
            "the portal scopes nearBy to the type asked for; this is what that looks like")

        let duplicate = try #require(report.possibleDuplicates.first)
        #expect(report.possibleDuplicates.count == 1)
        #expect(duplicate.numero == "OCO/00000/2000")
        #expect(duplicate.distance < Submitter.duplicateRadiusMetres)
        #expect(report.warnings.contains { $0.contains("already an open report") })

        // Open, same type, and still not a duplicate: 141 m away is somebody
        // else's rubbish. Excluded on distance alone.
        let far = try #require(report.location.nearBy.first { $0.numero == "OCO/00001/2000" })
        #expect(!far.isResolved)
        #expect(far.distance > Submitter.duplicateRadiusMetres)

        // Close enough, same type, already dealt with. A resolved report is not
        // a reason to stay quiet — if it is still there, it needs reporting.
        // Excluded on state alone.
        let done = try #require(report.location.nearBy.first { $0.numero == "OCO/00002/2000" })
        #expect(done.isResolved)
        #expect(done.distance < Submitter.duplicateRadiusMetres)
    }

    @Test("nearby reports come back sorted by distance")
    func nearBySorted() async throws {
        let (client, _) = try Fixture.client(returning: "geo-attributes-building")
        let report = try await Submitter(client: client).prepare(
            type: .litter, at: Projection.reference.wgs84, descricao: "x")

        let distances = report.location.nearBy.map(\.distance)
        #expect(distances == distances.sorted())
        #expect(distances.allSatisfy { $0 > 0 && $0 < 500 })
    }
}

// MARK: - House numbers

@Suite("House numbers")
struct HouseNumberTests {

    @Test("split verbatim, leading space included")
    func verbatim() {
        // Exactly what the verified 201 submission sent.
        #expect(splitHouseNumber("Rua Exemplo, 210") == " 210")
    }

    @Test("letter suffixes and ranges survive")
    func suffixes() {
        #expect(splitHouseNumber("Rua Qualquer, 12A") == " 12A")
        #expect(splitHouseNumber("Rua Qualquer, 12-14") == " 12-14")
        #expect(splitHouseNumber("Rua Qualquer, 3º") == " 3º")
    }

    @Test("a tail that is not a number yields empty, not a word in a number field")
    func notANumber() {
        #expect(splitHouseNumber("Praça do Comércio") == "")
        #expect(splitHouseNumber("Praça do Comércio, Lisboa") == "")
        #expect(splitHouseNumber("Rua Exemplo, ") == "")
        #expect(splitHouseNumber("") == "")
    }
}

// MARK: - The two morada shapes

@Suite("Address shapes")
struct MoradaTests {

    @Test("building and street matches are told apart")
    func distinguished() {
        let building = Morada(idtipo: "2", morada: "Rua Exemplo, 210", codSig: "1000000000000")
        let street = Morada(idtipo: "8", designacao: "Rua Exemplo", codVia: "34311")

        #expect(!building.isStreetMatch)
        #expect(street.isStreetMatch)
        #expect(building.label == "Rua Exemplo, 210")
        #expect(street.label == "Rua Exemplo")
    }

    /// Regression: reaching for `.morada` on a street match used to throw in the
    /// TypeScript client. In Swift it would be a nil unwrap; the point stands.
    @Test("a street match has no house number to split")
    func streetHasNoNumber() throws {
        let street = Morada(idtipo: "8", designacao: "Rua Qualquer", codVia: "34311")
        let label = try #require(street.label)
        #expect(splitHouseNumber(label) == "")
    }

    @Test("label is nil when neither shape is present")
    func neitherShape() {
        #expect(Morada(idtipo: "999").label == nil)
    }

    /// The portal is inconsistent about whether these codes are JSON strings or
    /// numbers. Either must resolve rather than failing the whole address.
    @Test("codes decode whether sent as strings or numbers")
    func lenientCodes() throws {
        let asNumbers = Data(
            #"{"idtipo": 2, "morada": "Rua Exemplo, 210", "cod_sig": 1000000000000}"#.utf8)
        let morada = try JSONDecoder().decode(Morada.self, from: asNumbers)

        #expect(morada.idtipo == "2")
        #expect(morada.codSig == "1000000000000")
        #expect(!morada.isStreetMatch)
    }
}
