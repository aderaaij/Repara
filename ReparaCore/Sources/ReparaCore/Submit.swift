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

    /// How many photographs one report may carry.
    ///
    /// The portal's own form counts them and stops at three: `report.html`
    /// shows `adicionar Foto 1/2/3` in turn and, once `chkFotoNumber > 2`,
    /// swaps in a dead button reading *"Só é possivel adicionar 3 fotos!"*.
    ///
    /// That is a **client-side** count, which is exactly why this cap is
    /// enforced here too. A fourth part would probably be accepted by the
    /// endpoint and then quietly dropped — and silently losing one of the
    /// photographs somebody walked out to take is worse than refusing to take
    /// a fourth in the first place.
    public static let maxPerReport = 3

    /// The byte budget for one photograph.
    ///
    /// **Inferred, and deliberately nowhere near the ceiling it infers.** There
    /// are three data points and not one of them is a documented limit:
    ///
    /// | Request | Photos | Result |
    /// | --- | --- | --- |
    /// | 4 844 588 B, the captured browser session | 1 | 201 |
    /// | ~6.8 MB, the TypeScript client | 2 | 201 |
    /// | ~6 MB, this client | 1 | 500, body mentioning size |
    ///
    /// The only reading that fits all three is a limit **per file** rather than
    /// per request: 4.8 MB in one file was fine, ~3.4 MB each in two files was
    /// fine, and ~6 MB in one file was not. So the per-file ceiling sits
    /// somewhere between 4.84 MB and ~6 MB, and the whole-request ceiling is at
    /// least 6.8 MB. Note that the failure arrived as a **500**, not a 413 —
    /// the size was in the body, so nothing can be concluded from a status code
    /// alone here.
    ///
    /// Narrowing it further would mean filing real reports until one is
    /// refused, and every attempt that *succeeds* dispatches a council worker.
    /// So this does not probe it. 1.2 MB is a quarter of the smallest size known
    /// to have been accepted; three of them still come in under that one
    /// verified request; and a 2048 px JPEG of a street scene rarely reaches it
    /// anyway. `PhotoScaler` is what holds photographs to it.
    public static let maxBytes = 1_200_000
}

// MARK: - Errors

public enum SubmitError: Error, CustomStringConvertible {
    case emptyDescription
    case descriptionTooLong(count: Int, max: Int)
    case tooManyPhotos(count: Int, max: Int)
    case confirmationDoesNotMatch
    case unexpectedResult(String)

    /// What to show the user. Every case here is actionable, so unlike
    /// `PortalError` none of them falls through to `description`.
    public func message(in locale: Locale) -> String {
        switch self {
        case .emptyDescription:
            return String(
                localized: "submit.empty-description",
                defaultValue: "Describe what is wrong, so the council can act on it.",
                bundle: .module.strings(for: locale), locale: locale)
        case let .descriptionTooLong(count, max):
            return String(
                localized: "submit.description-too-long",
                defaultValue: """
                    The description is \(count) characters; the portal accepts \(max). Trim it by \
                    \(count - max) — the portal would otherwise truncate it without saying so.
                    """,
                bundle: .module.strings(for: locale), locale: locale)
        case let .tooManyPhotos(count, max):
            return String(
                localized: "submit.too-many-photos",
                defaultValue: """
                    This report has \(count) photographs; Na Minha Rua LX takes \(max). Remove \
                    \(count - max) — the portal would otherwise drop them without saying which.
                    """,
                bundle: .module.strings(for: locale), locale: locale)
        case .confirmationDoesNotMatch:
            return String(
                localized: "submit.confirmation-does-not-match",
                defaultValue: """
                    This report changed after it was reviewed. Check it again before filing — the \
                    confirmation applies to the exact report that was on screen.
                    """,
                bundle: .module.strings(for: locale), locale: locale)
        case let .unexpectedResult(body):
            return String(
                localized: "submit.unexpected-result",
                defaultValue: """
                    The portal returned something unexpected: \(body.prefix(200)). The report may \
                    or may not have been filed — check My reports before trying again.
                    """,
                bundle: .module.strings(for: locale), locale: locale)
        }
    }

    public var description: String {
        switch self {
        case .emptyDescription:
            return "Describe what is wrong, so the council can act on it."
        case let .descriptionTooLong(count, max):
            return """
                The description is \(count) characters; the portal accepts \(max). Trim it by \
                \(count - max) — the portal would otherwise truncate it without saying so.
                """
        case let .tooManyPhotos(count, max):
            return """
                This report has \(count) photographs; Na Minha Rua LX takes \(max). Remove \
                \(count - max) — the portal would otherwise drop them without saying which.
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

    /// The same resolved report carrying a different set of photographs.
    ///
    /// **A new `id`, and that is the point.** Adding or removing evidence
    /// changes what is being filed, so any `ReviewConfirmation` taken against
    /// the previous one is refused and the user has to look again — the same
    /// rule that governs editing the text or dragging the pin.
    ///
    /// What it deliberately does *not* do is resolve anything. The pin has not
    /// moved, so the address, the freguesia and the nearby reports are all
    /// still the answers this client already has; re-preparing would spend a
    /// request at a municipal server to be told the same thing, and would drop
    /// the resolved address on the floor if that request happened to fail.
    public func with(photos: [Photo]) throws -> PreparedReport {
        guard photos.count <= Photo.maxPerReport else {
            throw SubmitError.tooManyPhotos(count: photos.count, max: Photo.maxPerReport)
        }
        return PreparedReport(
            obj: obj,
            type: type,
            photos: photos,
            location: location,
            possibleDuplicates: possibleDuplicates
        )
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

    /// How close another report has to be to be the same problem rather than a
    /// similar one two doors down. Public because the cross-type check in the
    /// app applies the same radius — one number, so the Review screen cannot
    /// warn about a booked collection 80 m away while staying silent about a
    /// duplicate at the same distance.
    public static let duplicateRadiusMetres = 50.0

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
        // Caught here rather than at submit, so a report that cannot be filed
        // says so on the screen where the photographs are still removable —
        // not after somebody has read the Portuguese and tapped the gate.
        guard photos.count <= Photo.maxPerReport else {
            throw SubmitError.tooManyPhotos(count: photos.count, max: Photo.maxPerReport)
        }

        let location = try await Geo.resolve(client, at: coordinate, tipoId: type.id)

        // The type check is belt and braces, not a filter that does work: the
        // portal already scoped `nearBy` to the type this call asked for, and
        // every row of a captured 89-entry answer was that type. It stays
        // because the API is undocumented and unversioned, and a report of the
        // wrong type flagged as a duplicate would talk somebody out of filing a
        // real problem.
        //
        // **Reading it as cross-type duplicate detection is the mistake to
        // avoid.** It cannot be: the list only ever holds one type. Finding the
        // same problem filed under a different id needs another request, which
        // is `Geo.nearBy(tipoIds:)` and lives above this layer.
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

        // Sizes, counts and the type id — nothing here says who or where. This
        // is the line that explains a refused submission after the fact, and a
        // refused submission is the one failure nobody can afford to reproduce.
        let sizes = report.photos.map(\.byteCount).map(String.init).joined(separator: ",")
        Log.submit.notice(
            """
            \(mode == .live ? "live" : "dry-run", privacy: .public) tipo \
            \(report.type.id, privacy: .public) · \(report.photos.count, privacy: .public) photo(s) \
            [\(sizes, privacy: .public) B] · multipart \(body.data.count, privacy: .public) B
            """)

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
            Log.submit.error("filed but the answer had no occurrence number")
            throw SubmitError.unexpectedResult(String(describing: result))
        }
        // The occurrence number identifies a reporter and a place, so it is the
        // one thing about a success that stays private.
        Log.submit.notice("filed as \(result.numero)")
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
