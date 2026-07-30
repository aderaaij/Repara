import Foundation
import Testing

@testable import ReparaCore

/// What merging map pins is allowed to hide, which is nothing.
///
/// A cluster is a drawing decision, and the only thing that makes one safe is
/// that the reports it covers are still all there and still all of one kind. The
/// two ways it could lie — swallowing an open report inside a grey count, and
/// putting a number over a mixture of types nobody could name — are what these
/// pin.
@Suite("Clustering")
struct ClusterTests {

    /// Reports at a metre offset from the reference square, decoded through the
    /// real path rather than hand-built: `NearByOccurrence` has no memberwise
    /// init on purpose, because the fields it *doesn't* decode are the point.
    private func pins(
        _ specs: [(id: Int, east: Double, north: Double, tipoId: Int, open: Bool)]
    ) throws -> [NearByOccurrence] {
        let origin = Projection.reference.ptTm06
        let rows = specs.map { spec in
            """
            {
              "id": \(spec.id),
              "numero": "OCO/\(spec.id)/2000",
              "tipo_id": \(spec.tipoId),
              "geo_x": \(origin.x + spec.east),
              "geo_y": \(origin.y + spec.north),
              "naminharua_estado": "\(spec.open ? "Em curso" : "Resolvido")"
            }
            """
        }
        let decoded = try JSONDecoder().decode(
            [NearByOccurrence].self, from: Data("[\(rows.joined(separator: ","))]".utf8))
        return decoded.stripped(relativeTo: origin)
    }

    @Test("pins closer than the radius become one badge, and none is lost")
    func mergesAndKeepsEverything() throws {
        let found = try pins([
            (id: 1, east: 0, north: 0, tipoId: 262, open: false),
            (id: 2, east: 4, north: 0, tipoId: 262, open: false),
            (id: 3, east: 60, north: 0, tipoId: 262, open: false),
        ])

        let clusters = found.clustered(within: 20)

        #expect(clusters.count == 2)
        #expect(clusters.map(\.count).sorted() == [1, 2])
        #expect(clusters.flatMap(\.members).count == found.count)
        #expect(Set(clusters.flatMap(\.members).map(\.id)) == [1, 2, 3])
    }

    /// The badge would otherwise be a number over a mixture — and on a widened
    /// browse, which is the only time this list holds more than one type, there
    /// is no sentence that says what such a number counts.
    @Test("a cluster never spans two types, however close the pins are")
    func neverSpansTypes() throws {
        let clusters = try pins([
            (id: 1, east: 0, north: 0, tipoId: 262, open: false),
            (id: 2, east: 0.5, north: 0, tipoId: 256, open: false),
        ]).clustered(within: 40)

        #expect(clusters.count == 2)
        #expect(clusters.allSatisfy { $0.count == 1 })
    }

    /// The one that actually matters on a street: eighty-nine closed reports and
    /// a single open one, all on the same corner. Merging them would put the open
    /// report inside a grey badge, and the only pin that can change what somebody
    /// does would be invisible at the zoom the map opens at.
    @Test("an open report is never swallowed by a closed count")
    func openIsNeverHidden() throws {
        var specs = (1...12).map {
            (id: $0, east: Double($0) * 0.4, north: 0.0, tipoId: 262, open: false)
        }
        specs.append((id: 99, east: 1.0, north: 0.5, tipoId: 262, open: true))

        let clusters = try pins(specs).clustered(within: 40)

        #expect(clusters.count == 2)
        let open = try #require(clusters.first { !$0.isResolved })
        #expect(open.count == 1)
        #expect(open.nearest.id == 99)
        #expect(clusters.first { $0.isResolved }?.count == 12)
    }

    /// Emission order only. MapKit stacks map content by position rather than by
    /// the order it was given, so this does not decide what covers what — it
    /// decides that two identical redraws produce an identical list.
    @Test("closed clusters are emitted before open ones")
    func emissionOrder() throws {
        let clusters = try pins([
            (id: 1, east: 0, north: 0, tipoId: 262, open: true),
            (id: 2, east: 0.5, north: 0, tipoId: 262, open: false),
        ]).clustered(within: 40)

        #expect(clusters.map(\.isResolved) == [true, false])
    }

    @Test("the badge sits at the middle of what it covers")
    func centroid() throws {
        let clusters = try pins([
            (id: 1, east: -10, north: 0, tipoId: 262, open: false),
            (id: 2, east: 10, north: 0, tipoId: 262, open: false),
        ]).clustered(within: 40)

        let cluster = try #require(clusters.first)
        #expect(cluster.count == 2)
        #expect(
            Projection.forward(cluster.centre).distance(to: Projection.reference.ptTm06) < 1.0,
            "the centroid of ±10 m is the point itself")
    }

    /// Greedy from a seed, not transitive. Four pins fifteen metres apart down a
    /// street are within twenty metres of their neighbours but span forty-five,
    /// and one badge over the middle of that would sit on ground none of them is
    /// on.
    @Test("clustering does not chain along a street")
    func doesNotChain() throws {
        let clusters = try pins(
            (0..<4).map {
                (id: $0 + 1, east: Double($0) * 15, north: 0.0, tipoId: 262, open: false)
            }
        ).clustered(within: 20)

        #expect(clusters.count == 2)
        #expect(clusters.allSatisfy { $0.count == 2 })
    }

    @Test("a radius of zero leaves every pin alone")
    func zeroRadius() throws {
        let found = try pins([
            (id: 1, east: 0, north: 0, tipoId: 262, open: false),
            (id: 2, east: 0.1, north: 0, tipoId: 262, open: false),
        ])

        #expect(found.clustered(within: 0).count == 2)
    }

    /// The map redraws on every camera settle. If the answer depended on the
    /// order the server happened to send, pins would jump between two identical
    /// frames.
    @Test("the same reports cluster the same way whatever order they arrive in")
    func deterministic() throws {
        let specs = [
            (id: 4, east: 0.0, north: 0.0, tipoId: 262, open: false),
            (id: 1, east: 3.0, north: 1.0, tipoId: 262, open: false),
            (id: 7, east: 50.0, north: 0.0, tipoId: 262, open: true),
            (id: 2, east: 51.0, north: 2.0, tipoId: 262, open: true),
        ]
        let forwards = try pins(specs).clustered(within: 20)
        let backwards = try pins(specs.reversed()).clustered(within: 20)

        #expect(forwards.map(\.id) == backwards.map(\.id))
        #expect(
            forwards.map { $0.members.map(\.id) } == backwards.map { $0.members.map(\.id) })
    }

    /// The id has to survive a zoom, or SwiftUI treats the badge as a different
    /// pin and animates one out and another in over the same square metre.
    @Test("a cluster keeps its identity as the radius changes")
    func stableIdentity() throws {
        let found = try pins([
            (id: 5, east: 0, north: 0, tipoId: 262, open: false),
            (id: 9, east: 6, north: 0, tipoId: 262, open: false),
        ])

        #expect(found.clustered(within: 20).map(\.id) == [5])
        #expect(found.clustered(within: 2).map(\.id) == [5, 9])
    }
}
