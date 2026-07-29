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

    // MARK: Looking under more than one type

    /// The server answers for one type at a time, so checking a second costs a
    /// second request. There is no batching to find and no shortcut to take —
    /// this test exists so that anyone who thinks they have found one can see
    /// the price written down.
    @Test("one request per type, each carrying its own ocoTipo, in order")
    func oneRequestPerType() async throws {
        let (client, mock) = try Fixture.client(perType: [
            97: "geo-attributes-empty",
            256: "geo-attributes-monstros",
            257: "geo-attributes-empty",
        ])

        _ = try await Geo.nearBy(
            client, around: Projection.reference.wgs84, tipoIds: [97, 256, 257])

        #expect(mock.requests.count == 3)
        #expect(mock.requestedTypes == [97, 256, 257])
    }

    /// The mattress: nothing under fly-tipping, a live collection request 8 m
    /// away under the type nobody thought to look at.
    @Test("a collection request booked under another type is found")
    func findsTheBookedCollection() async throws {
        let (client, _) = try Fixture.client(perType: [
            97: "geo-attributes-empty",
            256: "geo-attributes-monstros",
        ])

        let search = try await Geo.nearBy(
            client, around: Projection.reference.wgs84, tipoIds: [97, 256])

        #expect(search.isComplete)
        #expect(search.found.count == 2)

        let booked = try #require(search.found.first)
        #expect(booked.tipoId == 256)
        #expect(!booked.isResolved)
        #expect(Int(booked.distance.rounded()) == 8, "and nearest-first, as everywhere else")
    }

    /// "Nothing is booked here" and "we could not find out" must not look the
    /// same. A caller that cannot tell them apart eventually tells somebody the
    /// coast is clear because the network was down.
    @Test("a type that fails does not take the others with it, and is reported")
    func partialFailureIsVisible() async throws {
        // 257 has no fixture, so it 500s.
        let (client, _) = try Fixture.client(perType: [
            256: "geo-attributes-monstros"
        ])

        let search = try await Geo.nearBy(
            client, around: Projection.reference.wgs84, tipoIds: [256, 257])

        #expect(search.found.count == 2, "the type that answered still answered")
        #expect(search.searched == [256])
        #expect(search.failed == [257])
        #expect(!search.isComplete)
    }

    @Test("every type failing is not an empty result")
    func totalFailureIsNotAllClear() async throws {
        let (client, _) = try Fixture.client(perType: [:])

        let search = try await Geo.nearBy(
            client, around: Projection.reference.wgs84, tipoIds: [256, 257])

        #expect(search.isEmpty)
        #expect(!search.isComplete, "which is what stops this reading as 'nothing here'")
    }

    /// Nothing guarantees the portal never returns one occurrence under two
    /// types, and showing somebody the same report twice under two headings
    /// would read as two problems.
    @Test("an occurrence returned under two types is listed once")
    func deduplicated() async throws {
        let (client, _) = try Fixture.client(perType: [
            256: "geo-attributes-monstros",
            257: "geo-attributes-monstros",
        ])

        let search = try await Geo.nearBy(
            client, around: Projection.reference.wgs84, tipoIds: [256, 257])

        #expect(search.found.count == 2, "not 4")
        #expect(Set(search.found.map(\.id)).count == 2)
    }

    /// The cross-type list is the one that reaches a model provider, so the
    /// privacy boundary has to hold on this path too — not just on `resolve`.
    @Test("the cross-type list carries no reporter identity")
    func crossTypeStripsIdentity() async throws {
        let (client, _) = try Fixture.client(perType: [
            256: "geo-attributes-monstros"
        ])

        let search = try await Geo.nearBy(
            client, around: Projection.reference.wgs84, tipoIds: [256])
        let summary = search.found.map(\.promptSummary).joined(separator: "\n")

        #expect(!summary.contains("@"))
        for leak in ["Sicrano", "Fulana", "SICRANO", "999900", "UTILIZADOR"] {
            #expect(!summary.contains(leak))
        }
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
