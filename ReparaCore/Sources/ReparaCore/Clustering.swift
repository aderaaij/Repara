import Foundation

/// Pins that sit on top of each other, drawn as one balloon with a count.
///
/// A hundred metres of one street can hold ninety reports of a single type — the
/// verified capture returned exactly that — and at the zoom these maps open at
/// they all land inside the same thirty points of glass. Overlapping balloons
/// hide their own number: the map says "some" where the truth is "ninety", and
/// the one report that is still open is somewhere underneath the pile.
///
/// **Two reports merge only when they are the same type and the same side of
/// open/closed.**
///
/// - The type, because a count is a count *of something*. This screen's whole
///   honesty problem is that the portal answers about one type at a time, so a
///   badge reading "12" over a widened search would be a number nobody could
///   state the meaning of.
/// - Open and closed never merge, because the amber pin is the only one that can
///   change what somebody does, and a grey "12" quietly containing it would hide
///   the single thing on the map worth seeing.
///
/// Nothing is ever dropped: every report in comes back inside exactly one
/// cluster, which `ClusterTests` pins. A map that silently loses a report is
/// worse than a crowded one.
public struct MapCluster: Identifiable, Sendable, Hashable {

    /// Nearest-first, and never empty.
    public let members: [NearByOccurrence]

    /// Where the badge is drawn: the centroid of the members, in metres, then
    /// projected back. Not the seed's own point — a badge covering three reports
    /// should not sit exactly on one of them and imply that one is the cluster.
    public let centre: LatLng

    /// The lowest occurrence id in the cluster.
    ///
    /// Stable as the map zooms, so a badge that grows or shrinks is redrawn in
    /// place rather than thrown away and animated in from nowhere.
    public let id: Int

    init(members: [NearByOccurrence]) {
        precondition(!members.isEmpty, "a cluster is at least one report")
        self.members = members
        self.id = members.lazy.map(\.id).min() ?? 0

        let count = Double(members.count)
        self.centre = Projection.inverse(
            PtTm06(
                x: members.reduce(0) { $0 + $1.x } / count,
                y: members.reduce(0) { $0 + $1.y } / count
            ))
    }

    public var count: Int { members.count }

    /// The nearest member: what a cluster of one draws as, and what a tap on a
    /// bigger one is asking about.
    public var nearest: NearByOccurrence { members[0] }

    /// Whether this is a cluster of closed reports. Never mixed — see the type
    /// note above.
    public var isResolved: Bool { members[0].isResolved }

    public var tipoId: Int { members[0].tipoId }

    /// Nearest first, ties broken by id so the order never depends on how the
    /// server happened to sort its answer.
    static func nearestFirst(_ a: NearByOccurrence, _ b: NearByOccurrence) -> Bool {
        // `distance` is `.nan` until `stripped(relativeTo:)` fills it in, and
        // NaN comparisons are false in both directions — which would make this
        // an invalid ordering and trap the sort.
        let first = a.distance.isFinite ? a.distance : .infinity
        let second = b.distance.isFinite ? b.distance : .infinity
        return first == second ? a.id < b.id : first < second
    }
}

extension Array where Element == NearByOccurrence {

    /// Merge pins closer together than `radiusMetres` into one badge each.
    ///
    /// The radius is the caller's, because it is a fact about the camera rather
    /// than about the reports: it is a marker's own footprint converted into
    /// metres on the ground at the current zoom, so zooming in shrinks it and
    /// the clusters come apart into the pins they were made of.
    ///
    /// Distances are measured in EPSG:3763 metres on the coordinates the portal
    /// sent, so a cluster is a real distance on the ground rather than a
    /// screen-space guess that drifts with latitude.
    ///
    /// **Greedy around a seed, not transitive.** The nearest unclustered report
    /// claims everything within the radius *of itself*, then the next unclaimed
    /// one starts again. Chaining would let a line of pins down a street merge
    /// end to end into a single badge sitting on ground that none of them is on.
    ///
    /// O(n²) within one type, over a list the portal caps at around ninety.
    public func clustered(within radiusMetres: Double) -> [MapCluster] {
        let buckets = Dictionary(grouping: self) {
            Bucket(tipoId: $0.tipoId, isResolved: $0.isResolved)
        }

        var clusters: [MapCluster] = []

        // Bucket keys sorted rather than taken in Dictionary order: the same
        // reports must give the same clusters every time, or a map reshuffles
        // its pins between two identical redraws.
        for bucket in buckets.keys.sorted() {
            let ordered = (buckets[bucket] ?? []).sorted(by: MapCluster.nearestFirst)
            var claimed = Set<Int>()

            for (seedIndex, seed) in ordered.enumerated() where !claimed.contains(seedIndex) {
                claimed.insert(seedIndex)
                var members = [seed]

                if radiusMetres > 0 {
                    for (index, other) in ordered.enumerated() where index > seedIndex {
                        guard !claimed.contains(index),
                            seed.point.distance(to: other.point) <= radiusMetres
                        else { continue }
                        claimed.insert(index)
                        members.append(other)
                    }
                }

                clusters.append(MapCluster(members: members))
            }
        }

        // Closed first, then by id. This is ordering for determinism, not for
        // z-order: MapKit stacks map content by position — southern in front of
        // northern — and nothing a caller emits changes that. So an open pin and
        // a closed one a few metres apart can overlap either way round, which is
        // why the open/closed split is carried by hue and size and by the list
        // below the map, and never by which one happens to be drawn on top.
        return clusters.sorted { first, second in
            first.isResolved == second.isResolved
                ? first.id < second.id
                : first.isResolved
        }
    }
}

/// Same type, same side of open/closed — the only two reports that may ever
/// become one badge.
private struct Bucket: Hashable, Comparable {
    let tipoId: Int
    let isResolved: Bool

    static func < (a: Bucket, b: Bucket) -> Bool {
        a.tipoId == b.tipoId ? (!a.isResolved && b.isResolved) : a.tipoId < b.tipoId
    }
}
