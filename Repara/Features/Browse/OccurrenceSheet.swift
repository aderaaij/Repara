import MapKit
import ReparaCore
import SwiftUI

/// Everything the council's server says about somebody else's report — which is
/// less than you would expect, half by accident and half on purpose.
///
/// By accident: `getGeoAttributes` is the only call that lists nearby reports
/// and it answers with a fixed set of fields. There is no occurrence-detail
/// endpoint in the captured session and no photograph in the answer. The
/// portal's own "already reported here?" panel shows a number, a state and a
/// street, and nothing else either.
///
/// On purpose: the fields that would say *who* — `requerente`, `email`,
/// `criador_id`, `logedUser`, and the street address in `local` — have no
/// `CodingKey` on `NearByOccurrence`, so this screen could not show them if it
/// wanted to. That is also why there is a map here and no address: where the
/// problem is, is a fact about the street; the address on the record is a fact
/// about a household.
///
/// Costs the council nothing. Every value here came back with the search that
/// listed it, and opening this spends no request at all.
struct OccurrenceSheet: View {
    let report: NearByOccurrence

    /// The pin on the report being drafted, when this was opened from a warning
    /// on the Review screen rather than from Browse.
    ///
    /// Present, it turns this sheet from "what is this report" into "**is this
    /// your problem or a different one**" — which is the only question a
    /// caution card is really asking. The map then draws both points instead of
    /// one, because two pins forty metres apart round a corner and two pins on
    /// the same doorway are the same warning and opposite answers, and no
    /// wording distinguishes them as fast as seeing it.
    var comparedTo: LatLng? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private var isOpen: Bool { !report.isResolved }

    /// Metres between this report and the pin being drafted.
    ///
    /// Measured here rather than taken from `report.distance`, which is the
    /// distance from whatever point the *search* centred on. On Review that is
    /// the pin, so they agree; keeping the arithmetic local means they cannot
    /// silently disagree if that ever stops being true.
    private var separation: Double? {
        guard let comparedTo else { return nil }
        return Projection.forward(report.coordinate).distance(to: Projection.forward(comparedTo))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    ReportPhotos(occurrence: report.id)
                    if let text = description { descriptionCard(text) }
                    facts
                    map
                    footnotes
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Repara.canvas)
            .navigationTitle(report.numero)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Header

    /// The council's own status word, quoted, and the type it was filed under —
    /// which is what a passer-by would need in order to talk about this report
    /// to anybody at the council.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StatusChip(text: report.estado, tone: isOpen ? .open : .context)
                Spacer(minLength: 8)
                if let year = report.filedYear {
                    // `String(year)`, not `Text("\(year)")`: a year interpolated
                    // into a `Text` is formatted as a number, and 2000 comes out
                    // "2 000" under a Portuguese locale.
                    Text("Filed \(String(year))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Always, unlike the list rows: this sheet covers the type bar, so
            // there is nothing else on screen saying what was reported here.
            if !report.tipo.isEmpty {
                Text(report.tipo)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // **The one place the app says this.** A closed report is not an
            // argument against filing, and that claim used to appear five times
            // across Browse, this sheet and Status — twice on one screen. Here
            // is where somebody is actually looking at a finished report and
            // could conclude the problem is handled, so here is where it earns
            // its space; everywhere else it was the app repeating itself.
            Group {
                if isOpen {
                    Text("Still open with the council.")
                } else {
                    Text("Marked done by the council. If the problem is back, file it again.")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            // Opened from a warning, this sheet has one job, and it is not
            // "read about this report" — it is deciding whether the warning
            // applies. Saying so puts the question in front of the evidence
            // rather than leaving somebody to reconstruct why they tapped.
            if let separation {
                Text(comparisonLine(separation))
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    /// What the distance means, without deciding for anybody.
    ///
    /// The thresholds are deliberately soft — "probably", "could be" — because
    /// this is a distance between two points on a map, and whether two points
    /// are the same problem is a question about the street, not about metres.
    /// A pothole and a broken streetlight ten metres apart are two problems; two
    /// fly-tipping reports forty metres apart on the same alley are often one.
    /// The photograph and the description below decide it; this only says how
    /// far apart they are and what that usually means.
    private func comparisonLine(_ metres: Double) -> String {
        let rounded = Int(metres.rounded())
        switch metres {
        case ..<15:
            return String(
                localized: "\(rounded) m from your pin — close enough to be the same thing.",
                bundle: locale.bundle, locale: locale)
        case ..<60:
            return String(
                localized:
                    "\(rounded) m from your pin — could be the same thing, or the next doorway.",
                bundle: locale.bundle, locale: locale)
        default:
            return String(
                localized: "\(rounded) m from your pin — probably a different spot.",
                bundle: locale.bundle, locale: locale)
        }
    }

    // MARK: Description

    private var description: String? {
        let text = report.descricao?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// In full and selectable, which is the reason this sheet exists: the row it
    /// was opened from clips at three lines.
    private func descriptionCard(_ text: String) -> some View {
        CardGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text("What was reported")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    // MARK: Facts

    private var facts: some View {
        CardGroup {
            VStack(spacing: 0) {
                // Only when this sheet is not already leading with a distance.
                // Comparing, the header says "8 m from your pin" and this row
                // would repeat it from a different origin — two numbers for one
                // fact, which is how a screen starts to look untrustworthy.
                if comparedTo == nil {
                    FactRow("Distance", distancePhrase(report.distance, in: locale))
                }
                if !report.freguesia.isEmpty {
                    if comparedTo == nil { RowDivider() }
                    FactRow("Freguesia", report.freguesia)
                }
                if !report.area.isEmpty {
                    RowDivider()
                    FactRow("Department", report.area)
                }
                if let reference = reference {
                    RowDivider()
                    FactRow("Reference", reference)
                }
                RowDivider()
                FactRow("Occurrence", report.numero)
            }
        }
    }

    private var reference: String? {
        let text = report.referencia?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    // MARK: Map

    /// Where it is, since there is no address to give. Non-interactive: this is
    /// a statement about one or two points, not somewhere to go browsing from.
    ///
    /// Opened for comparison it frames both pins and draws the line between
    /// them, and it labels them — an unlabelled second pin on a warning about
    /// somebody else's report is worse than no second pin, because there is no
    /// way to tell which one is being warned about.
    private var map: some View {
        Map(initialPosition: .region(region), interactionModes: []) {
            // A `String`, so this takes `Marker`'s verbatim overload. The empty
            // branch means "no label" — there is only one pin, so there is
            // nothing to tell apart — and as a `LocalizedStringKey` it became an
            // empty key in the catalogue for a translator to puzzle over.
            let theirs =
                comparedTo == nil
                ? "" : String(localized: "Theirs", bundle: locale.bundle, locale: locale)
            Marker(
                theirs,
                systemImage: isOpen ? "exclamationmark" : "checkmark",
                coordinate: coordinate
            )
            .tint(isOpen ? Repara.amber : Color(.systemGray))

            if let mine = comparedTo.map(Self.point) {
                MapPolyline(coordinates: [coordinate, mine])
                    .stroke(Repara.ink.opacity(0.55), style: .init(lineWidth: 2, dash: [5, 4]))
                Marker("Yours", systemImage: "mappin", coordinate: mine)
                    .tint(Repara.ink)
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .frame(height: comparedTo == nil ? 170 : 220)
        .clipShape(.rect(cornerRadius: Repara.Radius.card, style: .continuous))
        .allowsHitTesting(false)
    }

    /// Framed so both pins are comfortably inside, with a floor so two reports
    /// on the same doorstep do not open zoomed into the pavement.
    private var region: MKCoordinateRegion {
        guard let mine = comparedTo else {
            return MKCoordinateRegion(
                center: coordinate, latitudinalMeters: 140, longitudinalMeters: 140)
        }
        let across = max((separation ?? 0) * 3.5, 60)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (report.coordinate.lat + mine.lat) / 2,
                longitude: (report.coordinate.lng + mine.lng) / 2
            ),
            latitudinalMeters: across,
            longitudinalMeters: across
        )
    }

    private var coordinate: CLLocationCoordinate2D { Self.point(report.coordinate) }

    private static func point(_ at: LatLng) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: at.lat, longitude: at.lng)
    }

    // MARK: Footnotes

    /// One, and it answers a question the screen raises: there is a map here and
    /// no address, and the reason is that the address was never decoded.
    ///
    /// The other footnote explained that photographs are a second request made
    /// only on opening. That is a fact about this app's request budget — real,
    /// and of no use to somebody looking at somebody else's pothole.
    private var footnotes: some View {
        Text(
            """
            The reporter's name, email and address are never decoded, so Repara cannot show \
            them.
            """
        )
        .reparaFootnote()
        .padding(.top, 2)
    }
}
