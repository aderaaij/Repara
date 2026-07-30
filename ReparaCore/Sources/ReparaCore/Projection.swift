import Foundation

// MARK: - Coordinate types

/// WGS84 — what a phone's GPS, a map URL or MapKit hands you.
public struct LatLng: Equatable, Hashable, Sendable, Codable {
    public var lat: Double
    public var lng: Double

    public init(lat: Double, lng: Double) {
        self.lat = lat
        self.lng = lng
    }
}

/// EPSG:3763 (ETRS89 / Portugal TM06) — what the portal speaks internally.
public struct PtTm06: Equatable, Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// Metres between two projected points. The CRS is metric and Lisbon-local,
    /// so plain Pythagoras is exact enough for "is this the same pothole".
    public func distance(to other: PtTm06) -> Double {
        hypot(x - other.x, y - other.y)
    }
}

// MARK: - Errors

public enum ProjectionError: Error, CustomStringConvertible {
    case selfCheckFailed(driftMetres: Double, expected: PtTm06, got: PtTm06)
    case outsideLisbon(PtTm06)

    /// `selfCheckFailed` is not translated: it prints a drift in metres and two
    /// coordinate pairs, and it means the app is refusing to submit. That is a
    /// bug report, not a message.
    public func message(in locale: Locale) -> String {
        switch self {
        case .selfCheckFailed:
            return description
        case .outsideLisbon:
            return String(
                localized: "projection.outside-lisbon",
                defaultValue: """
                    That location is outside the Lisbon municipality, which Na Minha Rua LX \
                    does not cover.
                    """,
                bundle: .module.strings(for: locale), locale: locale)
        }
    }

    public var description: String {
        switch self {
        case let .selfCheckFailed(drift, expected, got):
            return """
                Coordinate projection self-check failed: the reference point projected \
                \(String(format: "%.1f", drift)) m off (tolerance \
                \(String(format: "%.0f", Projection.toleranceMetres)) m). \
                Expected (\(expected.x), \(expected.y)), got (\(got.x), \(got.y)). \
                Refusing to submit coordinates that may be wrong.
                """
        case .outsideLisbon:
            return """
                That location is outside the Lisbon municipality, which Na Minha Rua LX \
                does not cover.
                """
        }
    }
}

// MARK: - The projection

/// WGS84 ⇄ EPSG:3763, computed locally.
///
/// This must never be delegated to the portal's ArcGIS GeometryServer. Its
/// forward (4326 → 3763) call passes `transformation=108153`, which applies a
/// spurious datum shift and lands **114 m** from the truth — that bug is why
/// this project exists, and why the portal's own map picker centres in the
/// wrong place. See `Projection.portalForwardBug`.
///
/// The implementation is the Krüger series to sixth order in the third
/// flattening (Karney 2011), which is accurate to nanometres anywhere near the
/// central meridian — far tighter than the metre we need. `towgs84` is all
/// zeros for EPSG:3763, so there is no datum shift to apply: WGS84 latitude and
/// longitude go straight into a plain Transverse Mercator on GRS80.
public enum Projection {

    // MARK: Parameters
    //
    // +proj=tmerc +lat_0=39.6682583333333 +lon_0=-8.13310833333333
    // +k=1 +x_0=0 +y_0=0 +ellps=GRS80 +towgs84=0,0,0,0,0,0,0 +units=m

    /// GRS80 semi-major axis.
    private static let a = 6_378_137.0
    /// GRS80 inverse flattening.
    private static let inverseFlattening = 298.257222101
    private static let f = 1.0 / inverseFlattening
    /// First eccentricity.
    private static let e = (f * (2 - f)).squareRoot()
    /// Third flattening, the series parameter.
    private static let n = f / (2 - f)

    private static let k0 = 1.0
    private static let lat0 = 39.668_258_333_333_3 * .pi / 180
    private static let lon0 = -8.133_108_333_333_33 * .pi / 180
    private static let falseEasting = 0.0
    private static let falseNorthing = 0.0

    /// Rectifying radius: the radius of a sphere with the same meridian arc.
    private static let bigA: Double = {
        let n2 = n * n
        return a / (1 + n) * (1 + n2 / 4 + n2 * n2 / 64 + n2 * n2 * n2 / 256)
    }()

    /// Krüger series coefficients, geodetic → projected (Karney 2011, eq. 12).
    private static let alpha: [Double] = {
        let n2 = n * n, n3 = n2 * n, n4 = n3 * n, n5 = n4 * n, n6 = n5 * n
        return [
            n / 2 - (2.0 / 3) * n2 + (5.0 / 16) * n3 + (41.0 / 180) * n4
                - (127.0 / 288) * n5 + (7891.0 / 37800) * n6,
            (13.0 / 48) * n2 - (3.0 / 5) * n3 + (557.0 / 1440) * n4
                + (281.0 / 630) * n5 - (1_983_433.0 / 1_935_360) * n6,
            (61.0 / 240) * n3 - (103.0 / 140) * n4 + (15061.0 / 26880) * n5
                + (167_603.0 / 181_440) * n6,
            (49561.0 / 161_280) * n4 - (179.0 / 168) * n5 + (6_601_661.0 / 7_257_600) * n6,
            (34729.0 / 80640) * n5 - (3_418_889.0 / 1_995_840) * n6,
            (212_378_941.0 / 319_334_400) * n6,
        ]
    }()

    /// Krüger series coefficients, projected → geodetic (Karney 2011, eq. 15).
    private static let beta: [Double] = {
        let n2 = n * n, n3 = n2 * n, n4 = n3 * n, n5 = n4 * n, n6 = n5 * n
        return [
            n / 2 - (2.0 / 3) * n2 + (37.0 / 96) * n3 - (1.0 / 360) * n4
                - (81.0 / 512) * n5 + (96199.0 / 604_800) * n6,
            (1.0 / 48) * n2 + (1.0 / 15) * n3 - (437.0 / 1440) * n4
                + (46.0 / 105) * n5 - (1_118_711.0 / 3_870_720) * n6,
            (17.0 / 480) * n3 - (37.0 / 840) * n4 - (209.0 / 4480) * n5
                + (5569.0 / 90720) * n6,
            (4397.0 / 161_280) * n4 - (11.0 / 504) * n5 - (830_251.0 / 7_257_600) * n6,
            (4583.0 / 161_280) * n5 - (108_847.0 / 3_991_680) * n6,
            (20_648_693.0 / 638_668_800) * n6,
        ]
    }()

    /// Meridian arc from the equator to `lat_0`, subtracted from every northing.
    private static let m0: Double = k0 * bigA * meridionalArcParameter(sinLat: sin(lat0), tanLat: tan(lat0))

    // MARK: Forward

    /// WGS84 → EPSG:3763. The conversion the portal gets wrong.
    public static func forward(_ p: LatLng) -> PtTm06 {
        let phi = p.lat * .pi / 180
        var lambda = p.lng * .pi / 180 - lon0
        // Keep λ in (-π, π] so the series stays in its convergent range.
        while lambda > .pi { lambda -= 2 * .pi }
        while lambda < -.pi { lambda += 2 * .pi }

        let tauPrime = conformalTan(sinLat: sin(phi), tanLat: tan(phi))

        let cosLambda = cos(lambda)
        let xiPrime = atan2(tauPrime, cosLambda)
        let etaPrime = asinh(sin(lambda) / hypot(tauPrime, cosLambda))

        var xi = xiPrime
        var eta = etaPrime
        for j in 1...6 {
            let twoJ = 2.0 * Double(j)
            xi += alpha[j - 1] * sin(twoJ * xiPrime) * cosh(twoJ * etaPrime)
            eta += alpha[j - 1] * cos(twoJ * xiPrime) * sinh(twoJ * etaPrime)
        }

        return PtTm06(
            x: k0 * bigA * eta + falseEasting,
            y: k0 * bigA * xi - m0 + falseNorthing
        )
    }

    // MARK: Inverse

    /// EPSG:3763 → WGS84.
    public static func inverse(_ p: PtTm06) -> LatLng {
        let xi = (p.y - falseNorthing + m0) / (k0 * bigA)
        let eta = (p.x - falseEasting) / (k0 * bigA)

        var xiPrime = xi
        var etaPrime = eta
        for j in 1...6 {
            let twoJ = 2.0 * Double(j)
            xiPrime -= beta[j - 1] * sin(twoJ * xi) * cosh(twoJ * eta)
            etaPrime -= beta[j - 1] * cos(twoJ * xi) * sinh(twoJ * eta)
        }

        let sinhEta = sinh(etaPrime)
        let cosXi = cos(xiPrime)
        let tauPrime = sin(xiPrime) / hypot(sinhEta, cosXi)

        let phi = atan(inverseConformalTan(tauPrime))
        let lambda = atan2(sinhEta, cosXi)

        return LatLng(lat: phi * 180 / .pi, lng: (lon0 + lambda) * 180 / .pi)
    }

    // MARK: Series helpers

    /// tan of the conformal latitude, from tan of the geodetic latitude.
    private static func conformalTan(sinLat: Double, tanLat: Double) -> Double {
        let sigma = sinh(e * atanh(e * sinLat))
        return tanLat * (1 + sigma * sigma).squareRoot() - sigma * (1 + tanLat * tanLat).squareRoot()
    }

    /// Invert `conformalTan` by Newton's method. Converges in three or four
    /// passes at any latitude; the loop bound is a backstop, not a budget.
    private static func inverseConformalTan(_ tauPrime: Double) -> Double {
        let e2 = e * e
        var tau = tauPrime
        for _ in 0..<10 {
            let sinLat = tau / (1 + tau * tau).squareRoot()
            let tau1 = conformalTan(sinLat: sinLat, tanLat: tau)
            let dTau =
                (tauPrime - tau1) * (1 + (1 - e2) * tau * tau)
                / ((1 - e2) * ((1 + tau1 * tau1) * (1 + tau * tau)).squareRoot())
            tau += dTau
            if abs(dTau) < 1e-14 { break }
        }
        return tau
    }

    /// ξ for a point on the central meridian — i.e. the rectifying latitude,
    /// which multiplied by the rectifying radius gives the meridian arc.
    private static func meridionalArcParameter(sinLat: Double, tanLat: Double) -> Double {
        let xiPrime = atan(conformalTan(sinLat: sinLat, tanLat: tanLat))
        var xi = xiPrime
        for j in 1...6 {
            xi += alpha[j - 1] * sin(2.0 * Double(j) * xiPrime)
        }
        return xi
    }

    // MARK: - The self-check

    /// A coordinate pair confirmed against the portal's own ArcGIS
    /// GeometryServer, used to prove this implementation still agrees with it.
    ///
    /// The point is Praça do Comércio — a public square, chosen so the reference
    /// data identifies nothing and nobody. Verified by asking the GeometryServer
    /// to project it 3763 → 4326 with no `transformation` parameter; server and
    /// proj4 agreed to within a millimetre.
    ///
    /// NOTE: only the 3763 → 4326 direction is a valid reference. See
    /// `portalForwardBug` for why the other direction is not.
    public static let reference = (
        wgs84: LatLng(lat: 38.70757, lng: -9.1364),
        ptTm06: PtTm06(x: -87269.145_776_018_7, y: -106_176.892_427_275_36)
    )

    public static let toleranceMetres = 1.0

    /// What the portal's buggy forward call returns for the same point.
    ///
    /// The shift was measured at two locations several kilometres apart and came
    /// out the same to within centimetres, so it is a constant datum offset
    /// across the city rather than anything position-dependent.
    ///
    /// This constant exists so `ProjectionTests` can assert we do **not**
    /// reproduce it. Its whole purpose is to stop someone "fixing" the
    /// projection later by matching the portal.
    public static let portalForwardBug = (
        ptTm06: PtTm06(x: -87343.711_582_961_347, y: -106_263.591_255_215_14),
        shift: (dx: -74.57, dy: -86.7),
        magnitudeMetres: 114.4
    )

    /// How far the reference point lands from where it should. Computed once.
    public static let selfCheckDriftMetres: Double = {
        forward(reference.wgs84).distance(to: reference.ptTm06)
    }()

    /// Guard against a refactor, a compiler change or a bad merge silently
    /// moving our numbers.
    ///
    /// Cheap enough to sit in the hot path, and the failure mode it prevents —
    /// filing a report against the wrong address — is expensive. Call it at
    /// launch so a broken build fails immediately, and again before any submit.
    public static func verify() throws {
        guard selfCheckDriftMetres <= toleranceMetres else {
            throw ProjectionError.selfCheckFailed(
                driftMetres: selfCheckDriftMetres,
                expected: reference.ptTm06,
                got: forward(reference.wgs84)
            )
        }
    }

    // MARK: - Bounds

    /// Rough bounds of the Lisbon municipality in EPSG:3763, for a sanity check
    /// before spending a request on a point the portal cannot serve.
    private static let lisbonBounds = (
        xmin: -92000.0, xmax: -80000.0, ymin: -110_000.0, ymax: -95000.0
    )

    public static func isInLisbon(_ p: PtTm06) -> Bool {
        p.x >= lisbonBounds.xmin && p.x <= lisbonBounds.xmax
            && p.y >= lisbonBounds.ymin && p.y <= lisbonBounds.ymax
    }

    public static func isInLisbon(_ p: LatLng) -> Bool {
        isInLisbon(forward(p))
    }
}
