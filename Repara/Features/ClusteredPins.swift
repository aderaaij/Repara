import MapKit
import ReparaCore
import SwiftUI

/// The drawing half of `MapCluster` — one balloon per report until they start
/// landing on top of each other, then one badge with a count.
///
/// Shared by both maps that show other people's reports, because they have the
/// same problem: the portal answers with everything of one type within about
/// 100 m, and on a corner that gets reported weekly that is ninety balloons in
/// the space of a thumbnail. The Review map has it worse, not better — the pin
/// being placed is the whole point of that screen, and it was being buried.
///
/// The conventions are the ones already in use: amber and shouting for open,
/// grey and ticked for closed. A cluster keeps them, because `MapCluster` never
/// merges the two.
struct ClusteredPins: MapContent {
    let clusters: [MapCluster]

    /// What a single pin is labelled with — the distance on the browse map, the
    /// type on the review map. Clusters carry no label: a badge over several
    /// reports has nothing true to say in one line.
    var label: (NearByOccurrence) -> String

    var onTap: (MapCluster) -> Void = { _ in }

    var body: some MapContent {
        ForEach(clusters) { cluster in
            if cluster.count == 1 {
                Marker(
                    label(cluster.nearest),
                    systemImage: cluster.isResolved ? "checkmark" : "exclamationmark",
                    coordinate: coordinate(cluster)
                )
                .tint(cluster.isResolved ? Color(.systemGray) : Repara.amber)
                // The occurrence id, so a map that binds a selection gets a
                // report rather than a cluster. Badges are deliberately not
                // tagged: several reports under one balloon have no single
                // report to open, and they answer a tap by zooming instead.
                .tag(cluster.nearest.id)
            } else {
                Annotation(coordinate: coordinate(cluster)) {
                    ClusterBadge(count: cluster.count, isResolved: cluster.isResolved)
                        .onTapGesture { onTap(cluster) }
                } label: {
                    EmptyView()
                }
            }
        }
    }

    private func coordinate(_ cluster: MapCluster) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: cluster.centre.lat, longitude: cluster.centre.lng)
    }
}

/// A count of reports that are all one type and all one state.
///
/// Two axes apart, not one: the open badge is larger, ringed, and carries dark
/// numerals on amber; the closed badge is smaller, plain, and light numerals on
/// grey. Printed in black and white — a phone at 40% brightness in the sun —
/// they are still a bright disc and a dim one.
///
/// The numerals on amber are near-black rather than `Repara.ink` on purpose:
/// ink inverts between light and dark appearance and amber does not, so ink
/// would go pale-on-amber in the dark and stop being a number anybody can read.
private struct ClusterBadge: View {
    let count: Int
    let isResolved: Bool

    var body: some View {
        Text("\(count)")
            .font(.system(size: 13, weight: isResolved ? .semibold : .bold))
            .monospacedDigit()
            .foregroundStyle(isResolved ? Color.white : Color.black.opacity(0.85))
            .padding(.horizontal, 5)
            .frame(minWidth: size, minHeight: size)
            .background(isResolved ? Color(.systemGray).opacity(0.92) : Repara.amber, in: .capsule)
            .overlay {
                if !isResolved {
                    Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                }
            }
            .shadow(color: .black.opacity(isResolved ? 0.18 : 0.3), radius: 3, y: 1)
            .accessibilityLabel(
                "\(count) \(isResolved ? "closed" : "open") reports at this spot")
    }

    private var size: CGFloat { isResolved ? 26 : 30 }
}

/// How close two pins have to be **on the ground** before they are drawn as one:
/// a marker's own footprint, converted into metres at the current zoom.
///
/// That is what makes zooming in take a cluster apart — the same reports, a
/// smaller radius — rather than needing a second, screen-space idea of distance
/// that would drift with latitude.
func clusterRadiusMetres(metresTall: Double, mapHeight: CGFloat) -> Double {
    guard metresTall > 0, mapHeight > 0 else { return 0 }
    return metresTall / Double(mapHeight) * markerFootprintPoints
}

/// How much ground the map is showing, top to bottom.
func mapMetresTall(_ span: MKCoordinateSpan) -> Double {
    span.latitudeDelta * metresPerDegreeLatitude
}

/// A map balloon is about 30 pt across, so two of them closer than that overlap.
private let markerFootprintPoints = 30.0

/// Constant to within a metre or so anywhere, and this is a scale factor for a
/// drawing decision rather than a coordinate — the real projection is
/// `Projection`, and nothing here feeds it.
private let metresPerDegreeLatitude = 111_320.0
