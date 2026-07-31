import MapKit
import ReparaCore
import SwiftUI

/// What has already been reported around a point — the read-only half of the
/// app.
///
/// **One look, every type, one request.** The app API's area search answers
/// about all 127 occurrence types at once within a radius, which is what the
/// council's own app shows you and what somebody actually wants to know:
/// what is going on where I am standing.
///
/// This screen used to be shaped by the opposite constraint. `getGeoAttributes`
/// answers about a single type, so browsing began by making the user pick one,
/// every answer carried a caveat that it covered 1 of 127, and looking under
/// related types was an offer priced in municipal requests. All of that was
/// scaffolding around a limit that no longer applies, and it has gone — the
/// type is now a filter over results already in hand, free to change and free
/// to clear.
///
/// The scope is still stated next to the answer rather than in a footer, and it
/// is still not a clearance: "all types within 225 m" is a real boundary, and
/// the wording never claims more than the circle drawn on the map.
///
/// The three ways it can answer are kept visibly apart, because two of them
/// used to look identical:
///
/// - **Found something** — amber keyline for open, grey for closed.
/// - **Nothing open nearby** — a tick, with the radius *inside the sentence*, so
///   it reads as "checked this area" and never as "nothing is wrong anywhere".
/// - **Could not check** — the hatch card. A failed search shows it instead of an
///   empty list, because a 503 that renders as a blank screen is a lie.
///
/// Everything shown comes through `NearByOccurrence`, so the addresses, names
/// and emails the servers send alongside each report were never decoded — see
/// `PrivacyTests` and `AreaSearchTests`. Nothing on this screen can file
/// anything.
struct NearbyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    let browser: NearbyBrowser

    @State private var camera: MapCameraPosition = .automatic
    /// Where the map is now, as opposed to where the answer on screen came from.
    @State private var centre: LatLng?
    @State private var showingTypePicker = false

    /// The report whose sheet is open, from a row or from a pin.
    @State private var detail: NearByOccurrence?

    /// Map selection, which is a cluster id rather than an occurrence id: a
    /// badge covering several reports has no single report to open, so only
    /// single-pin clusters lead anywhere.
    @State private var selectedPin: Int?

    /// Closed reports start collapsed. They are the bulk of every answer the
    /// portal gives — the verified capture was 89 of 89 — and a screen that
    /// opens with eighty-nine grey rows buries the one amber row that could
    /// change what somebody does.
    @State private var showsClosed = false

    /// How tall the map is on the ground and in points, which together are the
    /// zoom. Seeded with what `centreCamera` opens at, so the first draw
    /// clusters correctly rather than after the first camera settle.
    @State private var metresTall = 400.0
    @State private var mapHeight = Self.mapHeightPoints

    /// The last centre this view set itself, so a camera settle can be told
    /// apart from a finger. Once the map has been moved deliberately, a late GPS
    /// fix must not yank it back.
    @State private var programmaticCentre: LatLng?
    @State private var userMovedMap = false
    @State private var didCentreOnFix = false
    @State private var didAutoSearch = false

    var body: some View {
        VStack(spacing: 0) {
            map
            typeBar
            Divider()
            results
        }
        .background(Repara.canvas)
        .sheet(isPresented: $showingTypePicker) {
            @Bindable var browser = browser
            // Nothing is searched on dismissal any more: narrowing to a type
            // filters what is already here, so the picker spends nothing.
            TypePickerView(selection: $browser.typeFilter)
        }
        .sheet(item: $detail) { report in
            OccurrenceSheet(report: report)
        }
        .onChange(of: selectedPin) { _, tag in
            // A tapped pin opens the same sheet a tapped row does. Cleared
            // straight away so tapping the same pin twice opens it twice.
            guard let tag, let report = browser.results.first(where: { $0.id == tag }) else {
                return
            }
            selectedPin = nil
            detail = report
        }
        .task { await autoSearch() }
        .onChange(of: model.location.coordinate) { _, fix in
            // The fix usually lands after the map has already drawn. Follow it
            // once, and only while the map is still where this view put it.
            guard let fix, !didCentreOnFix, !userMovedMap, browser.searchedAt == nil else { return }
            didCentreOnFix = true
            centreCamera(on: fix)
            Task { await autoSearch() }
        }
    }

    // MARK: Map

    private var map: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera, selection: $selectedPin) {
                UserAnnotation()

                // What the answer on screen actually covered. Drawn around the
                // point that was searched, not the point the map has drifted to.
                if let searchedAt = browser.searchedAt {
                    MapCircle(
                        center: CLLocationCoordinate2D(
                            latitude: searchedAt.lat, longitude: searchedAt.lng),
                        radius: Double(browser.radiusMetres)
                    )
                    .foregroundStyle(Repara.amber.opacity(0.08))
                    .stroke(Repara.amber.opacity(0.45), lineWidth: 1)
                }

                // Same convention as the Review map: amber and shouting for
                // open, grey and ticked for done — and a count where several
                // of one kind land on the same few points of glass.
                ClusteredPins(clusters: clusters, label: distanceLabel) { cluster in
                    zoom(into: cluster)
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .mapControls { MapUserLocationButton() }
            .overlay { CentreReticle() }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { mapHeight = $0 }
            .onMapCameraChange(frequency: .onEnd) { context in
                let point = context.region.center
                let moved = LatLng(lat: point.latitude, lng: point.longitude)
                centre = moved
                // The zoom, for clustering. Read on settle rather than
                // continuously: pins that re-merge under a moving finger are
                // harder to read than pins that resolve when it lifts.
                metresTall = mapMetresTall(context.region.span)
                if let programmaticCentre,
                    Projection.forward(moved).distance(to: Projection.forward(programmaticCentre))
                        > 5
                {
                    userMovedMap = true
                }
            }
            .onAppear(perform: centreOnStart)

            searchButton
                .padding(.bottom, 14)
        }
        .frame(height: Self.mapHeightPoints)
    }

    private static let mapHeightPoints: CGFloat = 280

    /// The pins as drawn: one per report until they overlap, then one badge per
    /// group of the same type and the same state.
    ///
    /// Recomputed as the camera settles rather than held in state, which is what
    /// makes a zoom take the clusters apart. Ninety reports is a few thousand
    /// distance comparisons on numbers already in memory — cheaper than the
    /// redraw it feeds.
    private var clusters: [MapCluster] {
        browser.results.clustered(
            within: clusterRadiusMetres(metresTall: metresTall, mapHeight: mapHeight))
    }

    /// Where the next search would centre. The circle on the map shows where the
    /// last one did, and the two only line up until the map is moved.
    ///
    /// Deliberately not a blue dot and not a pin: blue is where the user is, and
    /// a pin is what the Review map uses for a thing being placed. This places
    /// nothing.
    private struct CentreReticle: View {
        var body: some View {
            ZStack {
                Circle()
                    .strokeBorder(.primary.opacity(0.55), lineWidth: 1.5)
                    .frame(width: 22, height: 22)
                Circle()
                    .fill(.primary.opacity(0.55))
                    .frame(width: 4, height: 4)
            }
            .shadow(color: .black.opacity(0.25), radius: 1)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var searchButton: some View {
        if browser.isSearching {
            GlassChip {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching…")
                }
            }
        } else if let centre, browser.shouldOfferSearch(at: centre) {
            Button {
                Task { await searchHere() }
            } label: {
                GlassChip {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text(browser.searchedAt == nil ? "Search here" : "Search this area")
                    }
                    .foregroundStyle(Repara.ink)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Type filter

    /// What the answer covers, and the filter over it.
    ///
    /// The filter is a *narrowing*, never a question — so it carries a clear
    /// button rather than only a picker. Somebody who filtered to potholes and
    /// then wonders what else is around must be one tap from the whole answer,
    /// because everything needed to show it is already in memory.
    private var typeBar: some View {
        HStack(spacing: 10) {
            Button {
                showingTypePicker = true
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        // Split rather than `?? "All types"`: coalescing makes
                        // the whole expression a `String`, which takes the
                        // verbatim `Text` overload and quietly leaves the
                        // fallback untranslated. The type name itself is data
                        // and is meant to be verbatim.
                        Group {
                            if let type = browser.typeFilter {
                                Text(type.localizedDescricao(in: locale))
                            } else {
                                Text("All types")
                            }
                        }
                        .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Text(scopeLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if browser.typeFilter != nil {
                Button {
                    browser.typeFilter = nil
                } label: {
                    Text("Clear")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Repara.ink)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Repara.card)
    }

    /// Never a clearance. The radius is always named, and when a filter is on it
    /// says what is being hidden as well as what is shown — a filtered screen
    /// that looks empty must not read as an empty street.
    private var scopeLine: String {
        let radius = browser.radiusMetres
        guard browser.typeFilter != nil else {
            // "· one request" used to hang off the end. What this costs the
            // council is a rule this app keeps, not a fact its reader needs.
            return String(
                localized: "Every type, within \(radius) m", bundle: locale.bundle, locale: locale)
        }
        let hidden = browser.found.count - browser.results.count
        // Pluralised in the catalogue rather than by appending an "s".
        return hidden > 0
            ? String(
                localized: "Filtered · \(hidden) other reports nearby are hidden",
                bundle: locale.bundle, locale: locale)
            : String(
                localized: "Filtered · within \(radius) m", bundle: locale.bundle, locale: locale)
    }

    // MARK: Results

    private var results: some View {
        ScrollView {
            VStack(spacing: 12) {
                // A failed search shows the hatch card, not an empty list.
                // Nothing is listed because nothing was learned, and it says so.
                if let failure = browser.failure {
                    CautionCard(
                        .unverified,
                        title: Text("Not checked — not cleared"),
                        message: Text(
                            """
                            The council's server did not answer for this area, so nothing is \
                            listed. \(failure)
                            """),
                        systemImage: "wifi.exclamationmark"
                    ) {
                        Button {
                            Task { await searchHere() }
                        } label: {
                            Label("Search again", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Repara.onInk)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 44)
                                .background(Repara.unknownInk, in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }

                if !browser.results.isEmpty {
                    resultsList
                } else if showsNothingFound {
                    nothingFound
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable {
            // The explicit way to get past the cache, for a place that was
            // searched a while ago. The type filter is untouched: it is a view
            // over the answer, not part of the question.
            guard let target = browser.searchedAt ?? centre else { return }
            await browser.search(at: target, refreshing: true)
        }
        .overlay { emptyState }
    }

    /// Open reports first and in full; closed ones behind one row that says how
    /// many there are.
    ///
    /// The portal's answer is overwhelmingly closed — the verified capture was
    /// 89 of 89 — because `nearBy` is the history of a spot and the council
    /// closes litter reports in days. Listing all of it at equal weight made the
    /// screen a wall of grey with the live report somewhere inside it.
    ///
    /// The count still leads, because on this screen the number *is* the
    /// finding: eighty-nine closed reports on one corner is what "this keeps
    /// happening here" looks like in municipal data.
    private var resultsList: some View {
        let open = browser.results.filter { !$0.isResolved }
        let closed = browser.results.filter(\.isResolved)

        return VStack(spacing: 8) {
            summary(open: open.count, closed: closed)

            if !open.isEmpty {
                CardGroup {
                    ForEach(Array(open.enumerated()), id: \.element.id) { index, report in
                        if index > 0 { RowDivider() }
                        row(report)
                    }
                }
            }

            if !closed.isEmpty {
                CardGroup {
                    DisclosureRow(
                        systemImage: "clock.arrow.circlepath",
                        // Pluralised in the catalogue, not by concatenating an
                        // "s" — Portuguese agrees the noun, not a suffix.
                        title: Text("\(closed.count) closed reports"),
                        subtitle: Text(closedSubtitle(closed)),
                        isExpanded: $showsClosed
                    ) {
                        ForEach(closed) { report in
                            RowDivider()
                            row(report)
                        }
                    }
                }
            }
        }
    }

    /// What was found, in one or two lines, before any row is read.
    ///
    /// The zero-open case still carries the trap it always did, for a different
    /// reason. It is no longer "we only asked about 1 of 127 types" — the answer
    /// covers all of them — but it *is* still bounded by a radius, and by
    /// whatever filter is on. So the boundary goes **inside the sentence**, and
    /// there is nothing green on it: this is a statement about a circle, not a
    /// verdict on a street.
    @ViewBuilder private func summary(open: Int, closed: [NearByOccurrence]) -> some View {
        if open == 0 {
            VStack(alignment: .leading, spacing: 3) {
                // One whole sentence per branch, rather than a scope phrase
                // spliced into the middle of a shared one. The emphasis still
                // puts the boundary inside the claim — that is the point of the
                // sentence — but "under X" and "within N m" do not land in the
                // same position in every language, so each has to be a sentence
                // a translator can move words around in.
                Group {
                    if let type = browser.typeFilter {
                        Text(
                            "Nothing open *under \(type.localizedDescricao(in: locale).lowercased())* here"
                        )
                    } else {
                        Text("Nothing open *within \(browser.radiusMetres) m* here")
                    }
                }
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

                Text(closedLine(closed))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("\(open) open within \(browser.radiusMetres) m")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("\(closed.count) closed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    /// Five closed reports on one corner is a coincidence; eighty-nine is a fact
    /// about the place. Only the second gets to say so — and it says it with the
    /// years, because "63 closed since 2021, 20 of them this year" is a street
    /// the council is losing, where "63 closed" is only a heap.
    ///
    /// The years come off the report numbers and can be absent (see
    /// `NearByOccurrence.filedYear`), so every clause here is optional and the
    /// sentence still reads without any of them.
    private func closedLine(_ closed: [NearByOccurrence]) -> String {
        let count = closed.count
        let radius = browser.radiusMetres
        // `String(_:)`, not interpolated as an `Int`: a localised integer takes a
        // grouping separator, and pt-PT would have printed the year 2021 as
        // "2 021".
        let from = closed.filedYears.map { String($0.lowerBound) }

        // One whole sentence per shape rather than clauses appended to a growing
        // string. ", filed since 2021" has to sit in a particular place in an
        // English sentence and somewhere else in a Portuguese one.
        let line: String
        switch (closed.filedYears, from) {
        case let (.some(years), .some(from)) where years.lowerBound == years.upperBound:
            line = String(
                localized: "\(count) closed reports within \(radius) m, filed in \(from)",
                bundle: locale.bundle, locale: locale)
        case let (.some, .some(from)):
            line = String(
                localized: "\(count) closed reports within \(radius) m, filed since \(from)",
                bundle: locale.bundle, locale: locale)
        default:
            line = String(
                localized: "\(count) closed reports within \(radius) m",
                bundle: locale.bundle, locale: locale)
        }

        // The chronic tail is its own sentence, joined rather than grown onto
        // the end of the last one.
        let thisYear = closed.filed(in: Self.currentYear)
        if thisYear >= Self.chronicThreshold {
            let tail = String(
                localized: "\(thisYear) of them this year alone.",
                bundle: locale.bundle, locale: locale)
            return "\(line) — \(tail)"
        }
        if count >= Self.chronicThreshold {
            let tail = String(
                localized: "this keeps happening here.", bundle: locale.bundle, locale: locale)
            return "\(line) — \(tail)"
        }
        return line + "."
    }

    private static let chronicThreshold = 5

    private static var currentYear: Int {
        Calendar.current.component(.year, from: .now)
    }

    /// The one line the collapsed history gets to say for itself, and it says
    /// the span: how far back this reaches is the reason to open it.
    ///
    /// It used to say "context, never an argument against filing" — with a
    /// footnote directly underneath the same group saying it again in other
    /// words, and `OccurrenceSheet` saying it a third time one tap in. The claim
    /// is true and it now lives there, next to the single closed report somebody
    /// might actually misread. A row whose job is to describe what is inside it
    /// should describe what is inside it.
    private func closedSubtitle(_ closed: [NearByOccurrence]) -> String {
        guard let years = closed.filedYears else {
            return String(
                localized: "Context for this spot", bundle: locale.bundle, locale: locale)
        }
        // Years built with `String(_:)` for the same reason as `closedLine`.
        let span =
            years.lowerBound == years.upperBound
            ? String(years.lowerBound)
            : "\(String(years.lowerBound))–\(String(years.upperBound))"
        return String(localized: "Filed \(span)", bundle: locale.bundle, locale: locale)
    }

    /// Amber keyline for open, grey for closed, and the closed ones sit on a
    /// dimmed row. Visibly present, visibly not open — which is the whole job,
    /// because a closed report is context and never an argument against filing.
    ///
    /// The whole row opens the detail sheet. It used to unclip its own text,
    /// which meant a tap did something different depending on how long somebody
    /// else's description happened to be.
    private func row(_ report: NearByOccurrence) -> some View {
        let isOpen = !report.isResolved
        let text = report.descricao?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(isOpen ? Repara.amber : Color(.systemGray4))
                .frame(width: 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(report.numero)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(isOpen ? .primary : .secondary)
                    Spacer(minLength: 8)
                    StatusChip(text: report.estado, tone: isOpen ? .open : .context)
                }

                if !text.isEmpty {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(isOpen ? .primary : .secondary)
                        .lineLimit(3)
                }

                // Always, unless filtered to a single type — the list spans
                // every type by default, so a row that does not say which one
                // it is cannot be read.
                if browser.typeFilter == nil, !report.tipo.isEmpty {
                    Text(report.tipo)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Text(metaLine(report))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(isOpen ? Color.clear : Color(.systemFill).opacity(0.35))
        .contentShape(.rect)
        .onTapGesture { detail = report }
    }

    /// Year, distance, freguesia. The year leads because it is the only thing
    /// here that says whether this is history or now — and it is absent rather
    /// than guessed when the number does not carry one.
    private func metaLine(_ report: NearByOccurrence) -> String {
        let parts = [
            report.filedYear.map(String.init),
            distancePhrase(report.distance, in: locale),
            report.freguesia.isEmpty ? nil : report.freguesia,
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Nothing found

    private var showsNothingFound: Bool {
        browser.hasSearched && !browser.isSearching && browser.failure == nil
    }

    /// **The only green tick on this screen**, and the boundary is inside the
    /// sentence.
    ///
    /// The tick is safe here for the same reason it always was: it says what was
    /// checked. It used to name the type, because the answer covered 1 of 127.
    /// It now names the radius, because the answer covers every type inside a
    /// circle and nothing outside it — a real boundary, just a different one.
    ///
    /// The filtered case is split out and gets **no tick at all**. "Nothing
    /// matched your filter" is not a check of anything, and a green mark over it
    /// would be the screen congratulating itself for a question the user
    /// narrowed.
    @ViewBuilder private var nothingFound: some View {
        if let type = browser.typeFilter, !browser.found.isEmpty {
            VStack(spacing: 0) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)

                Text("Nothing under this type here")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)

                // One key, with the count as a plural variation in the
                // catalogue rather than an "s" concatenated on the end — the
                // Portuguese needs a different verb agreement, not a suffix.
                Text(
                    """
                    No report of *\(type.localizedDescricao(in: locale).lowercased())* within \
                    \(browser.radiusMetres) m — but \(browser.found.count) other reports nearby \
                    are hidden by this filter.
                    """
                )
                .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)

                Button {
                    browser.typeFilter = nil
                } label: {
                    Text("Show all types")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                }
                .buttonStyle(InkButtonStyle(height: 52))
                .padding(.top, 18)
            }
            .padding(.horizontal, 10)
            .padding(.top, 26)
        } else {
            VStack(spacing: 0) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Repara.done)

                Text("Nothing open within \(browser.radiusMetres) m")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)

                // The boundary is already in the heading above, which is where
                // this screen's rule puts it. Spelling out "this says nothing
                // about the next street" underneath restated the heading and
                // was one of five near-identical disclaimers across the app.
                Text("Move the map and search again to check somewhere else.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
            }
            .padding(.horizontal, 10)
            .padding(.top, 26)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if browser.results.isEmpty, !browser.hasSearched, !browser.isSearching,
            browser.failure == nil
        {
            ContentUnavailableView(
                "Search where you are looking",
                systemImage: "magnifyingglass",
                description: Text(
                    "Move the map to the place you are curious about and tap Search here."
                )
            )
        }
    }

    // MARK: Actions

    private func searchHere() async {
        guard let target = centre ?? model.location.coordinate else { return }
        await browser.search(at: target)
    }

    /// Tapping a badge zooms to what it covers, which is how a count turns back
    /// into the reports it counted.
    ///
    /// Costs the council nothing: this only moves the camera over reports
    /// already in hand. Reports filed on the exact same doorstep stay one badge
    /// however far in it goes — there is no zoom that separates two pins a
    /// metre apart on a phone — and the count is still readable, which is why
    /// this is a shortcut and the list below is the answer.
    private func zoom(into cluster: MapCluster) {
        let points = cluster.members.map(\.point)
        let widest = max(
            (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0),
            (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0)
        )
        // Three times the spread, so the members land well apart rather than at
        // the very edges, with a floor for the ones sitting on top of each other.
        let across = max(widest * 3, 40)

        centre = cluster.centre
        programmaticCentre = cluster.centre
        withAnimation(.easeInOut(duration: 0.35)) {
            camera = .region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(
                        latitude: cluster.centre.lat, longitude: cluster.centre.lng),
                    latitudinalMeters: across,
                    longitudinalMeters: across
                ))
        }
    }

    /// The one search this screen makes without being asked, and only ever with
    /// a real fix in hand.
    ///
    /// Never from the fallback centre: spending a municipal request on Praça do
    /// Comércio because the GPS had not answered yet is a request wasted on a
    /// place nobody asked about.
    private func autoSearch() async {
        guard !didAutoSearch, !browser.hasSearched else { return }
        guard let fix = model.location.coordinate else { return }
        didAutoSearch = true
        await browser.search(at: fix)
    }

    private func centreOnStart() {
        guard case .automatic = camera else { return }
        if let fix = model.location.coordinate {
            didCentreOnFix = true
            centreCamera(on: fix)
        } else {
            // Falls back to Praça do Comércio — the same public square the
            // projection self-check uses, so the fallback identifies nobody.
            // Nothing is searched from here; it is only somewhere to look while
            // the fix arrives.
            centreCamera(on: Projection.reference.wgs84)
        }
    }

    private func centreCamera(on coordinate: LatLng) {
        camera = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: coordinate.lat, longitude: coordinate.lng),
                latitudinalMeters: 400,
                longitudinalMeters: 400
            ))
        centre = coordinate
        programmaticCentre = coordinate
    }

    private func distanceLabel(_ report: NearByOccurrence) -> String {
        guard report.distance.isFinite else {
            return String(localized: "nearby", bundle: locale.bundle, locale: locale)
        }
        return "\(Int(report.distance.rounded())) m"
    }
}
