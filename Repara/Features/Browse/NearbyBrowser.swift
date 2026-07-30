import Foundation
import Observation
import ReparaCore

/// Browsing what the council already has, around a point.
///
/// Held by `AppModel` so a look survives leaving the screen and coming back —
/// which is also what stops the return trip costing another request — but kept
/// as its own type, because browse state has nothing to do with the report
/// under construction and must never feed it. Nothing here reaches a
/// `PreparedReport`; these results are read-only and stay that way.
///
/// **One look is one request, whatever is being looked for.** This screen used
/// to be built around `getGeoAttributes`, which answers about a single
/// occurrence type — so "everything reported here" was 127 requests, the type
/// was a question the user had to answer before anything could be shown, and
/// looking under related types was a deliberate purchase. The app API's area
/// search answers about every type at once, so all of that is gone: the type is
/// now a filter over results already in hand, and it costs nothing to change.
///
/// The single-type call has not gone away — `Geo.nearBy` still backs duplicate
/// detection, where the question really is about one type. It is just no longer
/// how browsing works.
@MainActor
@Observable
final class NearbyBrowser {
    private let client: PortalClient
    private let session: AppSession

    init(client: PortalClient, session: AppSession) {
        self.client = client
        self.session = session
        let stored = UserDefaults.standard.integer(forKey: Self.storedTypeKey)
        typeFilter = stored > 0 ? Taxonomy.bundled.type(id: stored) : nil
    }

    // MARK: What is being browsed

    /// Narrow the reports on screen to one type. **Nil means all of them**,
    /// which is the default and the normal case.
    ///
    /// Changing this spends nothing and refetches nothing — the answer already
    /// covers every type, so this filters what is in hand. That is the whole
    /// difference from the old screen, where this was the question the request
    /// asked and changing it threw the results away.
    var typeFilter: TipoOcorrencia? {
        didSet {
            guard typeFilter?.id != oldValue?.id else { return }
            UserDefaults.standard.set(typeFilter?.id ?? 0, forKey: Self.storedTypeKey)
        }
    }

    private static let storedTypeKey = "browseTypeId"

    /// How far out the last answer reached.
    let radiusMetres = AreaSearch.defaultRadiusMetres

    // MARK: What came back

    /// Everything found, every type, nearest first.
    private(set) var found: [NearByOccurrence] = []
    private(set) var isSearching = false
    private(set) var failure: String?

    /// What is on screen, after the type filter.
    var results: [NearByOccurrence] {
        guard let typeFilter else { return found }
        return found.filter { $0.tipoId == typeFilter.id }
    }

    /// Every type present in the answer, most-reported first — what the filter
    /// can usefully offer, as opposed to all 127.
    var typesPresent: [(type: TipoOcorrencia, count: Int)] {
        Dictionary(grouping: found, by: \.tipoId)
            .compactMap { id, reports in
                guard let type = Taxonomy.bundled.type(id: id) else { return nil }
                return (type, reports.count)
            }
            .sorted { ($0.count, $1.type.descricao) > ($1.count, $0.type.descricao) }
    }

    /// Centre of the answer currently on screen — the point the distances are
    /// measured from and the circle is drawn around. Nil until a search lands.
    private(set) var searchedAt: LatLng?

    /// True once a search has been attempted, so an empty result reads as
    /// "nothing here" rather than "nothing yet".
    private(set) var hasSearched = false

    // MARK: Searching

    /// One search, one request — unless the same place was already asked about,
    /// in which case no request at all.
    ///
    /// The cache lives as long as the screen does. Reports arrive over days, so
    /// a few minutes of staleness costs nothing; pull to refresh forces a fresh
    /// answer when it matters.
    func search(at coordinate: LatLng, refreshing: Bool = false) async {
        hasSearched = true

        let key = Key(at: Projection.forward(coordinate))
        if !refreshing, let hit = cache[key] {
            found = hit.found
            searchedAt = hit.centre
            failure = nil
            return
        }

        isSearching = true
        defer { isSearching = false }
        do {
            let area = try await AreaSearch.occurrences(
                client, session: session, near: coordinate, radiusMetres: radiusMetres)
            // Converted to the one shape the map, the rows and the sheet are
            // written against. Sorted here because the server's `ordem` is a
            // request we make rather than a guarantee we have tested.
            let reports = area
                .map { NearByOccurrence($0) }
                .sorted { $0.distance < $1.distance }
            cache[key] = (centre: coordinate, found: reports)
            found = reports
            searchedAt = coordinate
            failure = nil
        } catch {
            failure = Self.describe(error)
        }
    }

    /// Whether the map has wandered far enough from the last answer to be worth
    /// spending another request on.
    ///
    /// Scaled to the radius rather than fixed: at 225 m an answer stays broadly
    /// true for a good deal further than the 40 m the old ~100 m call allowed.
    func shouldOfferSearch(at centre: LatLng) -> Bool {
        guard !isSearching else { return false }
        guard let searchedAt else { return true }
        return Projection.forward(centre).distance(to: Projection.forward(searchedAt))
            > Double(radiusMetres) * Self.restCanDriftFraction
    }

    private static let restCanDriftFraction = 0.35

    // MARK: Cache

    /// Same place to within ~10 m. No type in the key any more — one answer
    /// covers every type, so there is only one question to have asked.
    private struct Key: Hashable {
        let x: Int
        let y: Int

        init(at point: PtTm06) {
            x = Int((point.x / 10).rounded())
            y = Int((point.y / 10).rounded())
        }
    }

    private var cache: [Key: (centre: LatLng, found: [NearByOccurrence])] = [:]

    /// Drop everything read under one account. Signing out should not leave the
    /// previous user's neighbourhood sitting in memory behind the welcome screen.
    func reset() {
        cache.removeAll()
        found = []
        searchedAt = nil
        failure = nil
        hasSearched = false
    }

    // MARK: Errors

    private static func describe(_ error: any Error) -> String {
        let locale = AppLanguage.selected.locale
        switch error {
        case let error as PortalError: return error.message(in: locale)
        case let error as ProjectionError: return error.message(in: locale)
        default: return error.localizedDescription
        }
    }
}
