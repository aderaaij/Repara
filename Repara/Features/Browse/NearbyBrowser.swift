import Foundation
import Observation
import ReparaCore

/// Browsing what the council already has, one occurrence type at a time.
///
/// Held by `AppModel` so a look survives leaving the screen and coming back —
/// which is also what stops the return trip costing another request — but kept
/// as its own type, because browse state has nothing to do with the report
/// under construction and must never feed it. Nothing here reaches a
/// `PreparedReport`; these results are read-only and stay that way.
///
/// The cost model is the whole design. `getGeoAttributes` answers for a single
/// type within about 100 m, so one look is one request and "everything reported
/// here" would be 127 of them. Hence: searching is something the user asks for
/// by tapping, never something a pan sets off, and looking again at a place and
/// type already looked at comes out of `cache` instead of off the council's
/// server.
@MainActor
@Observable
final class NearbyBrowser {
    private let client: PortalClient

    init(client: PortalClient) {
        self.client = client
        let stored = UserDefaults.standard.integer(forKey: Self.storedTypeKey)
        type = stored > 0 ? Taxonomy.bundled.type(id: stored) : nil
    }

    // MARK: What is being browsed

    /// Remembered between visits. The type is the question this screen asks, and
    /// making somebody answer it again every time turns a glance into a chore.
    var type: TipoOcorrencia? {
        didSet {
            guard type?.id != oldValue?.id else { return }
            UserDefaults.standard.set(type?.id ?? 0, forKey: Self.storedTypeKey)
            results = []
            includedTypes = []
            searchedAt = nil
            failure = nil
        }
    }

    private static let storedTypeKey = "browseTypeId"

    /// Other types that could be holding the same physical problem as the one
    /// selected — the offer this screen makes, never something it acts on.
    ///
    /// Browsing is not urgent and nobody is standing in the street, so widening
    /// is a tap. (The Review screen is the opposite case and does spend the
    /// requests unasked, but only for collection requests; see
    /// `AppModel.checkForBookedCollections`.)
    var relatedTypes: [RelatedType] {
        guard let type else { return [] }
        return Taxonomy.bundled.related(to: type).filter { !includedTypes.contains($0.id) }
    }

    // MARK: What came back

    private(set) var results: [NearByOccurrence] = []
    private(set) var isSearching = false
    private(set) var failure: String?

    /// Every type the results on screen cover, in the order they were asked for.
    /// More than one only after a deliberate widening.
    private(set) var includedTypes: [Int] = []

    /// True once results span more than the selected type, so the list can say
    /// which type each row came from — otherwise a mixed list reads as one.
    var isWidened: Bool { includedTypes.count > 1 }

    /// Centre of the answer currently on screen — the point the distances are
    /// measured from and the circle is drawn around. Nil until a search lands.
    private(set) var searchedAt: LatLng?

    /// True once a search has been attempted, so an empty result reads as
    /// "nothing here" rather than "nothing yet".
    private(set) var hasSearched = false

    // MARK: Searching

    /// One search, one request — unless the same place and type were already
    /// asked for, in which case no request at all.
    ///
    /// The cache lives as long as the screen does. Reports arrive over days, so
    /// a few minutes of staleness costs nothing; pull to refresh forces a fresh
    /// answer when it matters.
    func search(at coordinate: LatLng, refreshing: Bool = false) async {
        guard let type else { return }
        hasSearched = true

        let key = Key(tipoId: type.id, at: Projection.forward(coordinate))
        if !refreshing, let hit = cache[key] {
            results = hit.found
            includedTypes = [type.id]
            searchedAt = hit.centre
            failure = nil
            return
        }

        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await Geo.nearBy(client, around: coordinate, tipoId: type.id)
            cache[key] = (centre: coordinate, found: found)
            results = found
            includedTypes = [type.id]
            searchedAt = coordinate
            failure = nil
        } catch {
            failure = Self.describe(error)
        }
    }

    /// Look again under the types that could be holding the same problem.
    ///
    /// One request per type, up to `Taxonomy.maxRelatedLookups` — the server has
    /// no way to answer for several at once. Searched around the point the
    /// answer on screen came from, never the point the map has since drifted to,
    /// so every distance in the merged list is measured from the same place.
    ///
    /// Shares the per-type cache with `search`, so widening and then selecting
    /// one of those types from the picker costs nothing the second time.
    func widen() async {
        guard let centre = searchedAt else { return }
        let wanted = relatedTypes.map(\.id)
        guard !wanted.isEmpty else { return }

        let point = Projection.forward(centre)
        let cached = wanted.filter { cache[Key(tipoId: $0, at: point)] != nil }
        let toFetch = wanted.filter { !cached.contains($0) }

        isSearching = true
        defer { isSearching = false }

        var found = results
        var reached: [Int] = []

        for tipoId in cached {
            found += cache[Key(tipoId: tipoId, at: point)]?.found ?? []
            reached.append(tipoId)
        }

        if !toFetch.isEmpty {
            do {
                let search = try await Geo.nearBy(client, around: centre, tipoIds: toFetch)
                for tipoId in search.searched {
                    cache[Key(tipoId: tipoId, at: point)] = (
                        centre: centre, found: search.found.filter { $0.tipoId == tipoId }
                    )
                }
                found += search.found
                reached += search.searched
                failure =
                    search.isComplete
                    ? nil
                    : "\(search.failed.count) of these types did not answer, so this is not the "
                        + "whole picture. Pull to refresh to try again."
            } catch {
                failure = Self.describe(error)
            }
        }

        var seen = Set<Int>()
        results = found.filter { seen.insert($0.id).inserted }.sorted { $0.distance < $1.distance }
        includedTypes += reached
    }

    /// Whether the map has wandered far enough from the last answer to be worth
    /// spending another request on. 40 m, against an answer that reaches ~100 m.
    func shouldOfferSearch(at centre: LatLng) -> Bool {
        guard type != nil, !isSearching else { return false }
        guard let searchedAt else { return true }
        return Projection.forward(centre).distance(to: Projection.forward(searchedAt))
            > Self.restCanMoveMetres
    }

    private static let restCanMoveMetres = 40.0

    // MARK: Cache

    /// Same type, same place to within ~10 m, same question.
    private struct Key: Hashable {
        let tipoId: Int
        let x: Int
        let y: Int

        init(tipoId: Int, at point: PtTm06) {
            self.tipoId = tipoId
            x = Int((point.x / 10).rounded())
            y = Int((point.y / 10).rounded())
        }
    }

    private var cache: [Key: (centre: LatLng, found: [NearByOccurrence])] = [:]

    /// Drop everything read under one account. Signing out should not leave the
    /// previous user's neighbourhood sitting in memory behind the welcome screen.
    func reset() {
        cache.removeAll()
        results = []
        includedTypes = []
        searchedAt = nil
        failure = nil
        hasSearched = false
    }

    // MARK: Errors

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let error as PortalError: return error.description
        case let error as ProjectionError: return error.description
        default: return error.localizedDescription
        }
    }
}
