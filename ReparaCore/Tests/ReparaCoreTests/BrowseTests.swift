import Foundation
import Testing

@testable import ReparaCore

/// Browsing is the one thing in this app that cannot dispatch anybody: it reads
/// what the portal already has and files nothing.
///
/// What it must still get right is the cost. One look is one request, and the
/// server answers for a single occurrence type — so a screen that tried to show
/// "everything reported here" would be 127 requests at a municipal service.
/// These tests pin the shape that makes that mistake visible.
@Suite("Browse")
struct BrowseTests {

    @Test("one look costs the council exactly one request")
    func oneRequestPerLook() async throws {
        let (client, mock) = try Fixture.client(returning: "geo-attributes-building")
        _ = try await Geo.nearBy(client, around: Projection.reference.wgs84, tipoId: 262)

        #expect(mock.requests.count == 1)
    }

    @Test("the request carries the projected point and the type asked for")
    func requestShape() async throws {
        let (client, mock) = try Fixture.client(returning: "geo-attributes-building")
        _ = try await Geo.nearBy(client, around: Projection.reference.wgs84, tipoId: 262)

        let url = try #require(mock.requests.first?.url)
        #expect(url.path().contains("getGeoAttributes"))

        let items = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        #expect(query["ocoTipo"] == "262")

        // Our own projection, not the portal's — the 114 m shift is the reason
        // this project exists, and a browse pin is as wrong as a report pin.
        // Compared against the verified reference within the same tolerance the
        // self-check uses, not bit-for-bit: `forward` is a computation, and the
        // reference is what ArcGIS answered.
        let sent = PtTm06(
            x: Double(try #require(query["x"])) ?? .nan,
            y: Double(try #require(query["y"])) ?? .nan
        )
        #expect(sent.distance(to: Projection.reference.ptTm06) <= Projection.toleranceMetres)
        #expect(
            sent.distance(to: Projection.portalForwardBug.ptTm06) > 100,
            "and nowhere near where the portal's own forward call would have put it")
    }

    @Test("results come back nearest-first with distances attached")
    func sortedWithDistances() async throws {
        let (client, _) = try Fixture.client(returning: "geo-attributes-building")
        let found = try await Geo.nearBy(
            client, around: Projection.reference.wgs84, tipoId: 262)

        #expect(found.count == 3)
        let distances = found.map(\.distance)
        #expect(distances == distances.sorted())
        #expect(distances.allSatisfy { $0.isFinite })
    }

    /// `Geo.resolve` throws `noAddressFound` for a point with no `morada`,
    /// because a submission needs an address to send anyone to. Browsing needs
    /// no such thing — "what has been reported around this park" is a fair
    /// question, and the portal answers it.
    @Test("a point with no address still browses")
    func noAddressStillBrowses() async throws {
        let (client, _) = try Fixture.client(returning: "geo-attributes-no-address")

        await #expect(throws: PortalError.self) {
            _ = try await Geo.resolve(client, at: Projection.reference.wgs84, tipoId: 262)
        }

        let found = try await Geo.nearBy(
            client, around: Projection.reference.wgs84, tipoId: 262)
        #expect(found.count == 2)
        #expect(found.first?.numero == "OCO/00011/2000", "and still nearest-first")
    }

    /// Not a claim about the radius the server actually uses — it is undocumented
    /// and may not be a circle. This is the number the browse screen tells the
    /// user it just covered, and it must stay a description rather than becoming
    /// a filter that hides results the portal chose to send.
    @Test("the advertised radius is only ever advertised")
    func radiusIsNotAFilter() async throws {
        let (client, _) = try Fixture.client(returning: "geo-attributes-building")
        let found = try await Geo.nearBy(
            client, around: Projection.reference.wgs84, tipoId: 262)

        #expect(Geo.nearByRadiusMetres == 100)
        #expect(
            found.count == 3,
            "everything the server sent must survive, whatever its distance")
    }
}
