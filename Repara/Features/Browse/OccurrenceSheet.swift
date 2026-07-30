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

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var photos = PhotoLoad.idle

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
                    photoStrip
                    if let text = description { descriptionCard(text) }
                    facts
                    map
                    footnotes
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .task { await loadPhotos() }
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

            Text(
                isOpen
                    ? "Still open with the council."
                    : "The council has marked this one done — which is a reason to file if the "
                        + "problem is back, not a reason to stay quiet."
            )
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
            return "\(rounded) m from your pin — close enough to be the same thing."
        case ..<60:
            return "\(rounded) m from your pin — could be the same thing, or the next doorway."
        default:
            return "\(rounded) m from your pin — probably a different spot."
        }
    }

    // MARK: Photographs

    /// The council's photographs of this report, fetched when the sheet opens
    /// and never before: one report opened is one request, and a list of eighty
    /// nine would otherwise be eighty-nine.
    ///
    /// The four states are kept apart for the reason every other check in this
    /// app keeps them apart — "no photograph on this report" and "we could not
    /// ask" are different facts, and the second must not render as the first.
    enum PhotoLoad {
        case idle
        case loading
        case loaded([Data])
        case failed(String)
    }

    @ViewBuilder private var photoStrip: some View {
        switch photos {
        case .idle:
            EmptyView()

        case .loading:
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Looking for photographs…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)

        case let .loaded(images) where images.isEmpty:
            Text("No photograph on this report.")
                .reparaFootnote()

        case let .loaded(images):
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                        if let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 240, height: 180)
                                .clipShape(.rect(cornerRadius: Repara.Radius.card, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)
            .frame(height: 180)

        case let .failed(why):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Could not load the photographs — \(why)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Try again") { Task { await loadPhotos(force: true) } }
                    .font(.footnote.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    /// At most `maxPhotos` images. The portal's own form takes three, so a
    /// report with more than a handful means the shape is not what we think it
    /// is, and downloading all of it would be a lot of somebody's data for a
    /// guess.
    private func loadPhotos(force: Bool = false) async {
        if case .loaded = photos, !force { return }
        if case .loading = photos { return }
        photos = .loading
        do {
            let urls = try await Photos.urls(model.client, occurrence: report.id)
            var images: [Data] = []
            for url in urls.prefix(Self.maxPhotos) {
                images.append(try await Photos.image(model.client, at: url))
            }
            photos = .loaded(images)
        } catch {
            photos = .failed(Self.describe(error))
        }
    }

    private static let maxPhotos = 4

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let error as PortalError: return error.description
        default: return error.localizedDescription
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
                    fact("Distance", distancePhrase(report.distance))
                }
                if !report.freguesia.isEmpty {
                    if comparedTo == nil { RowDivider() }
                    fact("Freguesia", report.freguesia)
                }
                if !report.area.isEmpty {
                    RowDivider()
                    fact("Department", report.area)
                }
                if let reference = reference {
                    RowDivider()
                    fact("Reference", reference)
                }
                RowDivider()
                fact("Occurrence", report.numero)
            }
        }
    }

    private var reference: String? {
        let text = report.referencia?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
            Marker(
                comparedTo == nil ? "" : "Theirs",
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

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "The list this came from carries no photographs; those are a second request, "
                    + "made only when a report is opened."
            )
            .reparaFootnote()

            Text(
                "The reporter's name, email and street address arrive with it and are never "
                    + "decoded, so Repara cannot show them."
            )
            .reparaFootnote()
        }
        .padding(.top, 2)
    }
}
