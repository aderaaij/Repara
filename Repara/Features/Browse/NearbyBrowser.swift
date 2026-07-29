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
            searchedAt = nil
            failure = nil
        }
    }

    private static let storedTypeKey = "browseTypeId"

    // MARK: What came back

    private(set) var results: [NearByOccurrence] = []
    private(set) var isSearching = false
    private(set) var failure: String?

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
            searchedAt = coordinate
            failure = nil
        } catch {
            failure = Self.describe(error)
        }
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
