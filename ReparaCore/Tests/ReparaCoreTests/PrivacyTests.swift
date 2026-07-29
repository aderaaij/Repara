import Foundation
import Testing

@testable import ReparaCore

/// `getGeoAttributes` returns a `nearBy` array carrying the **full name and
/// email of everyone who filed each nearby report**. The app needs none of it:
/// duplicate detection wants a type, a description, a status and a position.
///
/// These tests assert the identifying fields do not survive parsing. The bar is
/// deliberately blunt — no `@` anywhere in the parsed result — because a subtler
/// assertion is one someone can satisfy without meaning it.
@Suite("Privacy")
struct PrivacyTests {

    @Test("no reporter identity survives parsing")
    func identityDropped() async throws {
        let (client, _) = try Fixture.client(returning: "geo-attributes-building")
        let report = try await Submitter(client: client).prepare(
            type: .litter, at: Projection.reference.wgs84, descricao: "x")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let serialised = String(
            decoding: try encoder.encode(report.location.nearBy.map(Snapshot.init)), as: UTF8.self)

        for leak in [
            "Fulano", "Beltrano", "Cicrano", "DETAL", "EXAMPLE.INVALID", "UTILIZADOR",
            "999999", "999998", "999997", "1000-000",
        ] {
            #expect(!serialised.contains(leak), "nearBy must not leak \"\(leak)\"")
        }
        #expect(!serialised.contains("@"), "no email-like string may survive parsing")
    }

    /// The stronger claim: identifying fields are not merely dropped on the way
    /// out, they are never decoded in the first place. `NearByOccurrence` has no
    /// storage for them, so there is no raw shape to leak into a log, a cache,
    /// or a Claude prompt — the leak is structurally impossible, not forbidden.
    @Test("identifying fields have no storage to be dropped from")
    func noStorageForIdentity() throws {
        let raw = try Fixture.json("geo-attributes-building")
        let rawNearBy = try #require(raw["nearBy"] as? [[String: Any]])
        #expect(
            rawNearBy[0]["email"] != nil,
            "the fixture must actually contain the fields we claim to drop")

        let decoded = try JSONDecoder().decode(
            GeoAttributes.self, from: try Fixture.data("geo-attributes-building"))

        let mirror = Mirror(reflecting: decoded.nearBy[0])
        let properties = Set(mirror.children.compactMap(\.label))
        for forbidden in ["requerente", "email", "criadorId", "criador_id", "logedUser", "local"] {
            #expect(
                !properties.contains(forbidden),
                "NearByOccurrence must not have a \(forbidden) property")
        }
    }

    /// The fields duplicate detection genuinely needs must survive, or the
    /// stripping has gone too far and the Review screen cannot warn anybody.
    @Test("the useful duplicate-detection fields survive")
    func usefulFieldsKept() throws {
        let decoded = try JSONDecoder().decode(
            GeoAttributes.self, from: try Fixture.data("geo-attributes-building"))
        let nearBy = decoded.nearBy.stripped(relativeTo: Projection.reference.ptTm06)
        let first = try #require(nearBy.first)

        #expect(first.numero == "OCO/00002/2000")
        #expect(first.tipoId == 262)
        #expect(first.descricao == "já resolvido")
        #expect(first.estado == "Resolvido")
        #expect(first.isResolved)
        #expect(first.distance > 10 && first.distance < 20)
        #expect(Projection.isInLisbon(first.point))
    }

    /// Whatever the app sends to Claude to help judge duplicates must be built
    /// from the stripped type. A third party's name and email in a prompt is a
    /// disclosure to a third party.
    @Test("the Claude-facing summary of a neighbour carries no identity")
    func modelFacingSummary() throws {
        let decoded = try JSONDecoder().decode(
            GeoAttributes.self, from: try Fixture.data("geo-attributes-building"))
        let summary = decoded.nearBy
            .stripped(relativeTo: Projection.reference.ptTm06)
            .map(\.promptSummary)
            .joined(separator: "\n")

        #expect(!summary.contains("@"))
        #expect(!summary.localizedCaseInsensitiveContains("fulano"))
        #expect(summary.contains("Sacos"), "but it must still be useful")
    }
}

/// An `Encodable` view of the parsed value, used only so the assertions above
/// can search the whole thing as text.
private struct Snapshot: Encodable {
    let id: Int, numero: String, descricao: String?, referencia: String?
    let tipo: String, tipoId: Int, area: String, freguesia: String, estado: String
    let x: Double, y: Double, distance: Double

    init(_ n: NearByOccurrence) {
        id = n.id
        numero = n.numero
        descricao = n.descricao
        referencia = n.referencia
        tipo = n.tipo
        tipoId = n.tipoId
        area = n.area
        freguesia = n.freguesia
        estado = n.estado
        x = n.x
        y = n.y
        distance = n.distance
    }
}
