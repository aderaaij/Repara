import MapKit
import ReparaCore
import SwiftUI

/// What has already been reported around a point — the read-only half of the
/// app.
///
/// The portal has no "list occurrences" endpoint. The only way to see other
/// people's reports is `getGeoAttributes`, which answers for **one occurrence
/// type at a time** within about 100 m, so this screen is honest about that
/// rather than pretending to show a whole city: pick a type, search a place,
/// one request. Asking for all 127 types would be 127 requests at a municipal
/// service, which is not a thing to do because a map looked sparse.
///
/// Everything shown comes through `NearByOccurrence`, so the names and emails
/// the server sends alongside each report were never decoded — see
/// `PrivacyTests`. Nothing on this screen can file anything.
struct NearbyView: View {
    @Environment(AppModel.self) private var model
    let browser: NearbyBrowser

    @State private var camera: MapCameraPosition = .automatic
    /// Where the map is now, as opposed to where the answer on screen came from.
    @State private var centre: LatLng?
    @State private var showingTypePicker = false
    @State private var expanded: Set<Int> = []

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
        .sheet(isPresented: $showingTypePicker) {
            @Bindable var browser = browser
            TypePickerView(selection: $browser.type) {
                Task { await searchHere() }
            }
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
            Map(position: $camera) {
                UserAnnotation()

                // What the answer on screen actually covered. Drawn around the
                // point that was searched, not the point the map has drifted to.
                if let searchedAt = browser.searchedAt {
                    MapCircle(
                        center: CLLocationCoordinate2D(
                            latitude: searchedAt.lat, longitude: searchedAt.lng),
                        radius: Geo.nearByRadiusMetres
                    )
                    .foregroundStyle(.orange.opacity(0.06))
                    .stroke(.orange.opacity(0.35), lineWidth: 1)
                }

                ForEach(browser.results) { report in
                    // Same convention as the Review map: orange and shouting
                    // for open, grey and ticked for done.
                    Marker(
                        distanceLabel(report),
                        systemImage: report.isResolved ? "checkmark" : "exclamationmark",
                        coordinate: CLLocationCoordinate2D(
                            latitude: report.coordinate.lat, longitude: report.coordinate.lng)
                    )
                    .tint(report.isResolved ? .gray : .orange)
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .mapControls { MapUserLocationButton() }
            .overlay { CentreReticle() }
            .onMapCameraChange(frequency: .onEnd) { context in
                let point = context.region.center
                let moved = LatLng(lat: point.latitude, lng: point.longitude)
                centre = moved
                if let programmaticCentre,
                    Projection.forward(moved).distance(to: Projection.forward(programmaticCentre))
                        > 5
                {
                    userMovedMap = true
                }
            }
            .onAppear(perform: centreOnStart)

            searchButton
                .padding(.bottom, 12)
        }
        .frame(height: 280)
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
            Label("Searching…", systemImage: "ellipsis")
                .font(.footnote.bold())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: .capsule)
        } else if let centre, browser.shouldOfferSearch(at: centre) {
            Button {
                Task { await searchHere() }
            } label: {
                Label(
                    browser.searchedAt == nil ? "Search here" : "Search this area",
                    systemImage: "magnifyingglass"
                )
                .font(.footnote.bold())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: .capsule)
            }
            .buttonStyle(.plain)
            .shadow(radius: 3)
        }
    }

    // MARK: Type

    private var typeBar: some View {
        Button {
            showingTypePicker = true
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(browser.type?.descricao ?? "Choose a report type")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(browser.type == nil ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                    if let type = browser.type {
                        Text(type.area)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(.background)
    }

    // MARK: Results

    private var results: some View {
        List {
            if let failure = browser.failure {
                Section {
                    Text(failure).font(.footnote).foregroundStyle(.red)
                }
            }

            if !browser.results.isEmpty {
                widenOffer

                Section {
                    ForEach(browser.results) { report in
                        row(report)
                    }
                } header: {
                    Text(
                        "\(browser.results.count) reported within about \(Int(Geo.nearByRadiusMetres)) m"
                    )
                } footer: {
                    Text(
                        browser.isWidened
                            ? "\(browser.includedTypes.count) types searched, one request each. Nothing on this screen files anything."
                            : "One search asks the council's server once, for one type. Every other type is out there too — it just takes another search. Nothing on this screen files anything."
                    )
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            // The explicit way to get past the cache, for a place that was
            // searched a while ago. A widened look stays widened — dropping back
            // to one type on a refresh would quietly hide reports that were on
            // screen a second ago.
            guard let target = browser.searchedAt ?? centre else { return }
            let wasWidened = browser.isWidened
            await browser.search(at: target, refreshing: true)
            if wasWidened { await browser.widen() }
        }
        .overlay { emptyState }
    }

    // MARK: Widening

    /// The offer to look under the types that could be holding the same problem.
    ///
    /// Only ever an offer. It appears when the selected type actually has
    /// siblings, which is what makes it worth reading — a permanent "search
    /// wider" button teaches nobody anything, whereas this appearing on litter
    /// and not on graffiti says something true about how the council works.
    @ViewBuilder private var widenOffer: some View {
        let related = browser.relatedTypes
        if !related.isEmpty, browser.searchedAt != nil, !browser.isSearching {
            Section {
                Button {
                    Task { await browser.widen() }
                } label: {
                    Label(widenPrompt(related), systemImage: "arrow.triangle.branch")
                        .font(.footnote)
                }
                ForEach(related) { candidate in
                    Text(candidate.type.descricao)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(
                    "\(related.count) more request\(related.count == 1 ? "" : "s") to the council's server, one per type."
                )
            }
        }
    }

    private func widenPrompt(_ related: [RelatedType]) -> String {
        related.contains { $0.relation == .collectedByRequest }
            ? "Things like this are also collected by request — check whether one is already booked here"
            : "This could also have been filed under another type — check those too"
    }

    private func row(_ report: NearByOccurrence) -> some View {
        let isOpen = !report.isResolved
        let text = report.descricao?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(report.numero)
                    .font(.subheadline.monospaced())
                Spacer()
                Text(report.estado)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        isOpen ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.15),
                        in: .capsule)
            }

            if !text.isEmpty {
                Text(text)
                    .font(.footnote)
                    .lineLimit(expanded.contains(report.id) ? nil : 3)
            }

            // Only once the list spans types. Until then every row is the type
            // named in the bar above, and repeating it on each one is noise.
            if browser.isWidened, !report.tipo.isEmpty {
                Text(report.tipo)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text("\(distanceLabel(report)) away · \(report.freguesia)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture {
            // There is no occurrence-detail endpoint in the captured session, so
            // this is the whole of what can be shown — long descriptions just
            // stop being clipped.
            guard !text.isEmpty else { return }
            if expanded.contains(report.id) {
                expanded.remove(report.id)
            } else {
                expanded.insert(report.id)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if browser.type == nil {
            ContentUnavailableView {
                Label("Pick a type first", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(
                    "The portal answers for one occurrence type at a time, so browsing starts with choosing one."
                )
            } actions: {
                Button("Choose a report type") { showingTypePicker = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if browser.results.isEmpty && !browser.isSearching && browser.failure == nil {
            if browser.hasSearched {
                // The most important place the offer appears: an empty answer
                // under one type is exactly when somebody concludes the area is
                // clear, and the portal only ever answered about one type.
                ContentUnavailableView {
                    Label("Nothing of this type here", systemImage: "checkmark.circle")
                } description: {
                    Text(
                        "No open or closed \(browser.type?.descricao.lowercased() ?? "report") within about \(Int(Geo.nearByRadiusMetres)) m of that point. The portal only answers about the type asked for, so this is not the same as nothing being here."
                    )
                } actions: {
                    if !browser.relatedTypes.isEmpty, browser.searchedAt != nil {
                        Button(widenPrompt(browser.relatedTypes)) {
                            Task { await browser.widen() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Search where you are looking",
                    systemImage: "magnifyingglass",
                    description: Text(
                        "Move the map to the place you are curious about and tap Search here."
                    )
                )
            }
        }
    }

    // MARK: Actions

    private func searchHere() async {
        guard let target = centre ?? model.location.coordinate else { return }
        await browser.search(at: target)
    }

    /// The one search this screen makes without being asked, and only ever with
    /// a real fix in hand.
    ///
    /// Never from the fallback centre: spending a municipal request on Praça do
    /// Comércio because the GPS had not answered yet is a request wasted on a
    /// place nobody asked about.
    private func autoSearch() async {
        guard !didAutoSearch, browser.type != nil, !browser.hasSearched else { return }
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
        report.distance.isFinite ? "\(Int(report.distance.rounded())) m" : "nearby"
    }
}
