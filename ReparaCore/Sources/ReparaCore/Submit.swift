import Foundation

// MARK: - Photos

/// A photo bound for the council.
///
/// Always JPEG: it is the only format the portal has been observed to accept,
/// and council staff may not be able to open a HEIC even if it uploads — which
/// wastes a work order rather than failing loudly. The app controls its own
/// encoding, so unlike the command-line client it never has to guess at a file
/// on disk; `Capture` hands over JPEG and nothing else can get in.
public struct Photo: Sendable, Identifiable, Equatable {
    public let id = UUID()
    public let filename: String
    public let data: Data

    public var contentType: String { "image/jpeg" }
    public var byteCount: Int { data.count }

    public init(jpeg: Data, filename: String = "foto.jpg") {
        self.data = jpeg
        self.filename = filename
    }
}

// MARK: - Errors

public enum SubmitError: Error, CustomStringConvertible {
    case emptyDescription
    case descriptionTooLong(count: Int, max: Int)
    case confirmationDoesNotMatch
    case unexpectedResult(String)

    public var description: String {
        switch self {
        case .emptyDescription:
            return "Describe what is wrong, so the council can act on it."
        case let .descriptionTooLong(count, max):
            return """
                The description is \(count) characters; the portal accepts \(max). Trim it by \
                \(count - max) — the portal would otherwise truncate it without saying so.
                """
        case .confirmationDoesNotMatch:
            return """
                This report changed after it was reviewed. Check it again before filing — the \
                confirmation applies to the exact report that was on screen.
                """
        case let .unexpectedResult(body):
            return """
                The portal returned something unexpected: \(body.prefix(200)). The report may \
                or may not have been filed — check My reports before trying again.
                """
        }
    }
}

// MARK: - Prepared report

/// Everything a submission needs, resolved but **not sent**.
///
/// Preparing a report creates nothing and costs nobody anything. Only
/// `Submitter.submit` files it, and only with a matching `ReviewConfirmation`.
public struct PreparedReport: Sendable, Identifiable {
    /// Regenerated on every prepare. A `ReviewConfirmation` is bound to this
    /// value, so editing anything after reviewing invalidates the confirmation.
    public let id = UUID()
    public let obj: SubmitObj
    public let type: TipoOcorrencia
    public let photos: [Photo]
    public let location: ResolvedLocation

    /// Open reports of the same type within 50 m — likely duplicates.
    public let possibleDuplicates: [NearByOccurrence]

    public var warnings: [String] {
        var out: [String] = []
        if let warning = location.warning { out.append(warning) }
        if !possibleDuplicates.isEmpty {
            let count = possibleDuplicates.count
            out.append(
                count == 1
                    ? "There is already an open report of this type \(Int(possibleDuplicates[0].distance)) m away."
                    : "There are already \(count) open reports of this type within 50 m."
            )
        }
        if photos.isEmpty {
            out.append("No photo attached. A photo is the evidence a council worker acts on.")
        }
        return out
    }

    /// The exact bytes of the `obj` part, pretty-printed for a dry run.
    public func payloadJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(obj), as: UTF8.self)
    }
}

/// Proof that a human looked at a Review screen showing this exact report.
///
/// `Submitter.submit` will not take a report without one, and the confirmation
/// is bound to a specific `PreparedReport.id` — so a pin drag, a text edit or a
/// type change after confirming invalidates it and the user has to look again.
/// This is the app's equivalent of the MCP server's two-call token gate; the
/// difference is that an app has a screen, so the gate is a thing the user
/// physically taps rather than a token a model has to echo back.
public struct ReviewConfirmation: Sendable {
    let reportID: UUID

    /// Call this from the Review screen's confirm action, and nowhere else.
    public init(userConfirmed report: PreparedReport) {
        self.reportID = report.id
    }
}

/// Whether a submission actually leaves the phone.
///
/// Defaults to `.dryRun` everywhere it appears, because a forgotten argument
/// must never be the thing that files a work order with a municipal government.
public enum SubmitMode: Sendable, Equatable {
    case dryRun
    case live
}

public enum SubmitOutcome: Sendable, Equatable {
    /// The payload that *would* have been sent. Nothing left the phone.
    case dryRun(payload: String, photoBytes: Int, multipartBytes: Int)
    case filed(SubmitResult)
}

// MARK: - Submitter

public struct Submitter: Sendable {
    private let client: PortalClient

    /// The portal's own textarea is `maxlength="2048"` but its placeholder says
    /// "máximo(2000 caracteres)". Enforce the lower number — being truncated
    /// server-side would silently drop the end of a report.
    public static let maxDescription = 2000
    static let duplicateRadiusMetres = 50.0

    public init(client: PortalClient) {
        self.client = client
    }

    // MARK: Prepare

    /// Resolve everything a submission needs without sending it.
    public func prepare(
        type: TipoOcorrencia,
        at coordinate: LatLng,
        descricao: String,
        referencia: String = "",
        photos: [Photo] = []
    ) async throws -> PreparedReport {
        let text = descricao.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SubmitError.emptyDescription }
        guard text.count <= Self.maxDescription else {
            throw SubmitError.descriptionTooLong(count: text.count, max: Self.maxDescription)
        }

        let location = try await Geo.resolve(client, at: coordinate, tipoId: type.id)

        let duplicates = location.nearBy.filter {
            $0.tipoId == type.id && $0.distance <= Self.duplicateRadiusMetres && !$0.isResolved
        }

        return PreparedReport(
            obj: SubmitObj(
                tipoOcorrenciaId: type.id,
                descricao: text,
                referencia: referencia,
                geo: location.geo
            ),
            type: type,
            photos: photos,
            location: location,
            possibleDuplicates: duplicates
        )
    }

    // MARK: Submit

    /// `POST /ocorrencias` — files the report.
    ///
    /// **This creates a real work order.** A council worker reads it and is
    /// dispatched. There is no undo, no delete endpoint, and a wrong or
    /// duplicate report wastes public money. Hence: a confirmation bound to the
    /// exact report reviewed, and a mode that defaults to not sending.
    public func submit(
        _ report: PreparedReport,
        confirmation: ReviewConfirmation,
        mode: SubmitMode = .dryRun
    ) async throws -> SubmitOutcome {
        guard confirmation.reportID == report.id else {
            throw SubmitError.confirmationDoesNotMatch
        }
        // Re-checked here rather than only at resolve time: this is the last
        // moment before coordinates become someone's work order.
        try Projection.verify()

        let objData = try report.obj.encoded()

        var body = MultipartBody()
        body.append(name: "obj", value: objData)
        for photo in report.photos {
            body.append(
                name: "files",
                filename: photo.filename,
                contentType: photo.contentType,
                bytes: photo.data
            )
        }
        body.finish()

        guard mode == .live else {
            return .dryRun(
                payload: try report.payloadJSON(),
                photoBytes: report.photos.reduce(0) { $0 + $1.byteCount },
                multipartBytes: body.data.count
            )
        }

        let result = try await client.json(
            SubmitResult.self,
            from: "/ocorrencias",
            method: "POST",
            body: .raw(body.data, contentType: body.contentType),
            headers: ["Origin": Portal.origin]
        )
        guard result.id > 0, !result.numero.isEmpty else {
            throw SubmitError.unexpectedResult(String(describing: result))
        }
        return .filed(result)
    }

    // MARK: Status

    /// `GET /ocorrencias/my` — note the missing trailing slash. The portal's own
    /// frontend requests `/my/?page=1` and gets a 404 for it.
    public func myReports(page: Int = 1, pageSize: Int = 20) async throws -> [MyOccurrence] {
        try await client.json(
            [MyOccurrence].self,
            from: "/ocorrencias/my",
            query: ["page": String(page), "pageSize": String(pageSize)]
        )
    }
}
