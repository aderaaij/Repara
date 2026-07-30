import MapKit
import ReparaCore
import SwiftUI

/// The map that fixes the location properly — the single biggest quality
/// improvement this app has over the command line and the MCP server.
///
/// The pin is fixed to the centre of the view and the map moves under it,
/// rather than the pin being dragged across a still map. That is how the
/// precise-placement pattern works everywhere it works well: the target never
/// hides under a fingertip, and the position is exactly the camera centre.
///
/// `onMapCameraChange(frequency: .onEnd)` fires when the gesture settles, which
/// gives the debounce for free — one address lookup per placement, not one per
/// frame. This is a municipal service, not a load-test target.
struct PinMap: View {
    @Binding var coordinate: LatLng
    var isResolving: Bool
    var neighbours: [NearByOccurrence]
    var onSettle: () -> Void

    @State private var position: MapCameraPosition = .automatic
    @State private var hasCentred = false

    /// The zoom, for clustering. Seeded with what `onAppear` opens at.
    @State private var metresTall = 120.0
    @State private var mapHeight: CGFloat = 220

    var body: some View {
        Map(position: $position) {
            // Neighbours of one type on one doorstep are drawn as a count, so a
            // busy corner cannot hide the crosshair under a heap of balloons.
            // The pin being placed is what this screen is for.
            ClusteredPins(
                clusters: neighbours.clustered(
                    within: clusterRadiusMetres(metresTall: metresTall, mapHeight: mapHeight)),
                label: \.tipo
            )
        }
        .mapStyle(.standard(elevation: .flat))
        .overlay { Crosshair(isResolving: isResolving) }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { mapHeight = $0 }
        .onMapCameraChange(frequency: .onEnd) { context in
            metresTall = mapMetresTall(context.region.span)
            let centre = context.region.center
            let moved = LatLng(lat: centre.latitude, lng: centre.longitude)
            // Ignore the settle that follows our own initial centring.
            guard hasCentred else { return }
            guard Projection.forward(moved).distance(to: Projection.forward(coordinate)) > 0.5
            else { return }
            coordinate = moved
            onSettle()
        }
        .onAppear {
            position = .region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(
                        latitude: coordinate.lat, longitude: coordinate.lng),
                    latitudinalMeters: 120,
                    longitudinalMeters: 120
                ))
            // The camera settles once after being set; let that one pass.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                hasCentred = true
            }
        }
    }
}

private struct Crosshair: View {
    let isResolving: Bool

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "mappin")
                .font(.title)
                .foregroundStyle(.red)
                .shadow(radius: 2)
                .symbolEffect(.pulse, isActive: isResolving)
            // The pin's point, not its head, marks the spot.
            Circle()
                .fill(.red)
                .frame(width: 5, height: 5)
                .shadow(radius: 1)
        }
        .offset(y: -12)
        .allowsHitTesting(false)
    }
}
