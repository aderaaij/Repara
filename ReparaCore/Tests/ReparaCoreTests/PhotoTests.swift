import Foundation
import Testing

@testable import ReparaCore

/// The one call in this client whose response nobody has captured.
///
/// The path comes from the portal's own resource definitions, but the shape of
/// what comes back does not, so `Photos.parse` has to read several plausible
/// shapes and refuse to invent anything from the rest. These pin both halves —
/// what it accepts, and what it must never follow.
@Suite("Photos")
struct PhotoTests {

    private func parse(_ json: String) -> [String] {
        Photos.parse(Data(json.utf8)).map(\.absoluteString)
    }

    /// What `ocoDetail.html` implies: `ng-src="{{row}}"` over the array means the
    /// rows are bare URL strings.
    @Test("an array of paths reads as photographs, in order")
    func bareStrings() {
        #expect(
            parse(#"["/gopiv2/naminharuav2/ocorrencias/1/fotos/9", "/x/fotos/10"]"#) == [
                "https://naminharualx.cm-lisboa.pt/gopiv2/naminharuav2/ocorrencias/1/fotos/9",
                "https://naminharualx.cm-lisboa.pt/x/fotos/10",
            ])
    }

    @Test("objects answer with their URL field, not their other strings")
    func objects() {
        let json = """
            [{"legenda": "Antes da recolha", "url": "/fotos/1", "fase": "A"}]
            """
        #expect(parse(json) == ["https://naminharualx.cm-lisboa.pt/fotos/1"])
    }

    @Test("an envelope is unwrapped")
    func envelope() {
        #expect(parse(#"{"fotos": ["/fotos/1"]}"#) == ["https://naminharualx.cm-lisboa.pt/fotos/1"])
        #expect(
            parse(#"{"data": {"fotos": [{"src": "/fotos/2"}]}}"#)
                == ["https://naminharualx.cm-lisboa.pt/fotos/2"])
    }

    @Test("absolute portal URLs are kept as they are")
    func absolute() {
        let json = #"["https://naminharualx.cm-lisboa.pt/gopiv2/f/1.jpg"]"#
        #expect(parse(json) == ["https://naminharualx.cm-lisboa.pt/gopiv2/f/1.jpg"])
    }

    /// A client that fetches whatever a response points at can be pointed
    /// anywhere. The portal has no reason to serve its photographs from another
    /// host, so anything that leaves the origin is dropped rather than followed.
    @Test("anything off the portal's origin is refused")
    func refusesOffOrigin() {
        #expect(parse(#"["https://example.invalid/fotos/1.jpg"]"#).isEmpty)
        #expect(parse(#"[{"url": "http://evil.test/fotos/1"}]"#).isEmpty)
    }

    /// A report with no photograph and a shape we cannot read must not look like
    /// a network failure — both answer "nothing", and the caller says so quietly
    /// instead of raising an error about the council's server.
    @Test("nothing recognisable reads as no photographs, never as an error")
    func nothingRecognisable() {
        #expect(parse("[]").isEmpty)
        #expect(parse("{}").isEmpty)
        #expect(parse(#"{"total": 0}"#).isEmpty)
        #expect(parse(#"["Recolhido na semana passada"]"#).isEmpty)
        #expect(Photos.parse(Data("<html>not json at all</html>".utf8)).isEmpty)
    }

    @Test("a request goes to the occurrence's own photo path")
    func requestShape() async throws {
        let (session, mock) = MockURLProtocol.make { _ in .init(body: Data("[]".utf8)) }
        _ = try await Photos.urls(PortalClient(session: session), occurrence: 1621221)

        let url = try #require(mock.requests.first?.url)
        #expect(url.path().hasSuffix("/ocorrencias/1621221/fotos"))
    }

    /// One report opened, one request. Never a list: eighty-nine reports on a
    /// corner would be eighty-nine requests at a municipal server for pictures
    /// nobody asked to see.
    @Test("opening one report costs one request")
    func oneRequest() async throws {
        let (session, mock) = MockURLProtocol.make { _ in .init(body: Data("[]".utf8)) }
        _ = try await Photos.urls(PortalClient(session: session), occurrence: 1)

        #expect(mock.requests.count == 1)
    }
}
