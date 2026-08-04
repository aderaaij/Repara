import Foundation
import Testing

@testable import ReparaCore

/// `/ocorrencias/my` — your own reports, and the one place in this app where a
/// report's address is shown rather than dropped.
///
/// **Nobody has seen this endpoint's response body.** The captured session only
/// ever called `/my/?page=1`, which 404s on the trailing slash, so the fields
/// below come from the portal's own `my.html`, which binds them off each row of
/// this call's answer. Every one of them is therefore optional in the decoder,
/// and the third row of the fixture is the minimal shape the app read before
/// they existed — it has to keep decoding, or a widened reader would break the
/// screen it was widened for.
@Suite("My reports")
struct MyReportTests {

    private func rows() throws -> [MyOccurrence] {
        try JSONDecoder().decode([MyOccurrence].self, from: try Fixture.data("my-occurrences"))
    }

    @Test("the whole row survives, not just the five fields the list used")
    func fullRowDecodes() throws {
        let report = try #require(try rows().first)

        #expect(report.id == 1_000_800)
        #expect(report.numero == "OCO/00800/2000")
        #expect(report.descricao == "Sacos de lixo abandonados junto aos contentores.")
        #expect(report.tipo == "Sacos ou outros lixos abandonados")
        #expect(report.area == "Higiene Urbana")
        #expect(report.local == "Rua Exemplo 1, 1000-000 Lisboa")
        #expect(report.freguesia == "Freguesia Exemplo")
        #expect(report.responsavel == "Departamento Exemplo")
        #expect(report.dataCriacao == "12-03-2000")
    }

    /// The portal sends both spellings and they disagree: `estado` is the
    /// back-office word, `naminharua_estado` is the one the public portal shows.
    /// The public one wins, because it is the one a user would be quoted.
    @Test("naminharua_estado beats estado")
    func statusPrefersThePublicWord() throws {
        let report = try #require(try rows().first)
        #expect(report.estado == "Em curso")
        #expect(!report.isResolved)
    }

    /// The shape the app decoded before the row was widened. A field the portal
    /// does not send has to arrive as nothing, not as a decode failure — one
    /// missing key must never cost somebody the whole list of their reports.
    @Test("a row carrying only the basics still decodes")
    func minimalRowStillDecodes() throws {
        let report = try #require(try rows().last)

        #expect(report.numero == "OCO/00802/2002")
        #expect(report.tipo == "Candeeiro apagado")
        // Falls back to `estado` when the public spelling is absent.
        #expect(report.estado == "Concluído")

        #expect(report.area.isEmpty)
        #expect(report.freguesia.isEmpty)
        #expect(report.local == nil)
        #expect(report.responsavel == nil)
        #expect(report.dataCriacao == nil)
    }

    /// The year comes off the report number rather than off `data_criacao`, for
    /// the reason `NearByOccurrence.filedYear` does: the number's format is
    /// verified across 89 captured entries and the date field's is not.
    @Test("the filing year is read off the number, and only when it is plausible")
    func filedYear() throws {
        let all = try rows()
        #expect(all.map(\.filedYear) == [2000, 2001, 2002])

        let noYear = try JSONDecoder().decode(
            MyOccurrence.self, from: Data(#"{"numero": "OCO/00800/rascunho"}"#.utf8))
        #expect(noYear.filedYear == nil)
    }

    @Test("a resolved report says so")
    func resolvedIsRecognised() throws {
        #expect(try rows()[1].isResolved)
    }

    /// The same structural claim `PrivacyTests` makes about `NearByOccurrence`,
    /// made here because this type is the obvious place for it to erode: the row
    /// really does carry a name and an email, and this one is *yours*, which is
    /// exactly the argument someone would use for decoding them.
    ///
    /// The address is the deliberate exception and is asserted above — it is
    /// where your own report is, shown to the account that filed it. Identity is
    /// not: a row about you does not need to carry a copy of you.
    @Test("identity has no storage to be dropped from")
    func noStorageForIdentity() throws {
        let raw = try #require(
            JSONSerialization.jsonObject(with: try Fixture.data("my-occurrences"))
                as? [[String: Any]])
        #expect(
            raw[0]["email"] != nil && raw[0]["requerente"] != nil,
            "the fixture must actually contain the fields we claim to drop")

        let mirror = Mirror(reflecting: try #require(try rows().first))
        let properties = Set(mirror.children.compactMap(\.label))
        for forbidden in ["requerente", "email", "criadorId", "criador_id", "logedUser"] {
            #expect(
                !properties.contains(forbidden),
                "MyOccurrence must not have a \(forbidden) property")
        }

        // Blunt, like the `nearBy` version: no email-like string anywhere in the
        // parsed value, whatever it got called.
        for child in mirror.children {
            #expect(
                !String(describing: child.value).contains("@"),
                "\(child.label ?? "?") carries an email-like string")
        }
    }

    /// The trailing slash is the whole reason this path is written out by hand —
    /// the portal's own frontend asks for `/my/?page=1` and gets a 404 for it.
    @Test("the request goes to /ocorrencias/my with no trailing slash")
    func requestPath() async throws {
        let body = try Fixture.data("my-occurrences")
        let (session, mock) = MockURLProtocol.make { _ in .init(body: body) }

        let reports = try await Submitter(client: PortalClient(session: session)).myReports()
        #expect(reports.count == 3)

        let url = try #require(mock.requests.first?.url)
        #expect(url.path() == "/gopiv2/naminharuav2/ocorrencias/my")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains { $0.name == "page" && $0.value == "1" })
        #expect(query.contains { $0.name == "pageSize" && $0.value == "20" })
    }
}
