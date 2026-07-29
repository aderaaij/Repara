import Foundation
import Observation
import ReparaCore
import UIKit

/// The state behind the Capture → Draft → Resolve → Review → Submit flow.
///
/// The one rule this whole app is built around: **nothing submits without
/// passing through a Review screen the user has seen.** That is enforced two
/// ways here — `ReviewConfirmation` from `ReparaCore` can only be made from a
/// prepared report and is invalidated by any subsequent edit, and `submitMode`
/// defaults to `.dryRun` so a forgotten toggle never files anything.
@MainActor
@Observable
final class AppModel {

    // MARK: Dependencies

    let client: PortalClient
    let location = LocationProvider()
    let auth: Auth
    let submitter: Submitter
    /// Read-only browsing of what has already been reported. Held here for its
    /// lifetime — leaving the screen and coming back must not re-buy the answer —
    /// but it is nothing to do with the report being built below.
    let browse: NearbyBrowser
    private let drafter = Drafter()

    /// - Parameter session: Injected only by `ScreenshotMode`, which serves the
    ///   portal's endpoints from synthetic fixtures so the screenshots can be
    ///   regenerated without a network or an account. `nil` everywhere else, and
    ///   `PortalClient` builds its own configured session — this parameter adds
    ///   no path that behaves differently in a shipping build.
    init(session: URLSession? = nil) {
        let client = PortalClient(session: session)
        self.client = client
        self.auth = Auth(client: client)
        self.submitter = Submitter(client: client)
        self.browse = NearbyBrowser(client: client)
    }

    // MARK: Flow

    enum Stage: Equatable {
        case capture
        case drafting
        case review
        case filed(SubmitResult)
        case dryRan(payload: String, bytes: Int)
    }

    var stage: Stage = .capture
    var account: Utilizador?
    var busyMessage: String?
    var error: String?

    /// Lives here rather than in `RootView` so signing out can close the sheet
    /// as the welcome screen takes over behind it.
    var showingSettings = false

    /// `account == nil` means two different things at launch — signed out, or
    /// the stored cookie has not been checked yet. Without this the welcome
    /// screen flashes in front of every returning user for as long as
    /// `/utilizador` takes to answer.
    private(set) var isRestoringSession = true

    // MARK: The report under construction

    /// The full-resolution JPEG that goes to the council.
    var photo: Data?
    /// The downscaled copy that goes to the model provider. Never sent to the
    /// portal.
    private var photoForModel: Data?

    var userText = ""
    var type: TipoOcorrencia?
    var descricao = ""
    var referencia = ""
    var draftNotes: String?
    var draftConfidence: Drafter.Draft.Confidence?

    /// Where the pin is. Starts at the GPS fix; the user drags it onto the
    /// building frontage, which is the single biggest quality improvement this
    /// app offers over the other surfaces.
    var pin: LatLng?

    private(set) var prepared: PreparedReport?
    private(set) var isResolving = false
    private var resolveTask: Task<Void, Never>?

    // MARK: Settings

    /// **Defaults to a dry run.** Turning this off is a deliberate act, made in
    /// Settings, and the Review screen says loudly which mode it is in. A real
    /// submission dispatches a council worker and cannot be undone.
    var submitMode: SubmitMode {
        get { UserDefaults.standard.bool(forKey: "liveSubmit") ? .live : .dryRun }
        set { UserDefaults.standard.set(newValue == .live, forKey: "liveSubmit") }
    }

    /// Whether the *selected* provider has a key. Keys for the others may well
    /// be stored — switching provider must not silently keep drafting with the
    /// previous one's key.
    var hasAPIKey: Bool { ModelSettings.hasAPIKey }

    /// For the copy that tells the user which key is missing.
    var providerName: String { ModelSettings.provider.displayName }

    // MARK: Launch

    /// Run the projection self-check before anything else can happen.
    ///
    /// It needs no network and takes microseconds. If it ever fails, the app
    /// must not be used to file reports: every coordinate it produces would be
    /// suspect, and a wrong coordinate sends a worker to the wrong door.
    func start() async {
        // Whatever happens, stop showing the launch placeholder — a failed
        // projection check or a dead network must not leave the app spinning
        // with no way to read the error.
        defer { isRestoringSession = false }

        do {
            try Projection.verify()
        } catch {
            self.error = String(describing: error)
            return
        }
        location.start()
        await signInIfPossible()
    }

    func signInIfPossible() async {
        guard await auth.hasStoredCredentials else { return }
        do {
            account = try await auth.ensureSignedIn()
        } catch {
            self.error = describe(error)
        }
    }

    func signIn(username: String, password: String) async {
        busyMessage = "Signing in…"
        defer { busyMessage = nil }
        do {
            account = try await auth.logIn(Credentials(username: username, password: password))
            error = nil
        } catch {
            self.error = describe(error)
        }
    }

    func signOut() async {
        try? await auth.signOut()
        account = nil
        // The welcome screen replaces everything behind this sheet, so leaving
        // it open would sit a Settings form on top of the sign-up gate — and
        // leaving the flag set would spring it open again on the next sign-in.
        showingSettings = false
        // Someone else's neighbourhood should not still be in memory behind the
        // welcome screen — neither what was browsed nor what was looked up on
        // their behalf while filing.
        browse.reset()
        collectionCache.removeAll()
        startOver()
    }

    // MARK: Capture → Draft

    func accept(image: UIImage) {
        photo = PhotoScaler.forCouncil(image)
        photoForModel = PhotoScaler.forModel(image)
        pin = location.coordinate
    }

    /// One model call: photo in, `{tipo_id, descricao}` out — both editable on
    /// the Review screen afterwards.
    func makeDraft() async {
        guard let photoForModel else { return }
        stage = .drafting
        error = nil
        do {
            // No address and no nearby reports to pass: both are resolved from
            // the occurrence type, and the type is what this call produces.
            // Duplicates are judged after `resolve`, in `judgeDuplicates`.
            let draft = try await drafter.draft(
                photo: photoForModel,
                userText: userText,
                address: nil
            )
            type = draft.type
            descricao = draft.descricao
            draftNotes = draft.notesForUser
            draftConfidence = draft.confidence
        } catch {
            // A failed draft is not a dead end: the Review screen still works,
            // it just starts blank. Someone standing in the street should never
            // be blocked by the model being unavailable.
            self.error = describe(error)
        }
        stage = .review
        resolve()
    }

    /// Skip the model entirely and fill the report in by hand.
    func skipDraft() {
        stage = .review
        resolve()
    }

    // MARK: Resolve

    /// Re-resolve the address for the current pin. Debounced, because this is a
    /// municipal service and the pin moves continuously while a finger is on it.
    func resolve() {
        resolveTask?.cancel()
        guard let pin, let type else {
            prepared = nil
            return
        }
        let text = descricao.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.isEmpty ? "…" : text

        resolveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }

            let report: PreparedReport
            do {
                self.isResolving = true
                defer { self.isResolving = false }
                report = try await self.submitter.prepare(
                    type: type,
                    at: pin,
                    descricao: body,
                    referencia: self.referencia,
                    photos: self.photo.map { [Photo(jpeg: $0)] } ?? []
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.prepared = nil
                self.error = self.describe(error)
                self.clearDuplicateJudgement()
                self.clearCollectionCheck()
                return
            }

            guard !Task.isCancelled else { return }
            self.prepared = report
            self.error = nil

            // Both of these run *after* `isResolving` has dropped. Neither may
            // hold up the Submit button: somebody standing in the street can
            // file while the app is still looking things up, and a check that
            // gates submission is a check that will one day strand them.
            await self.checkForBookedCollections(for: report)
            guard !Task.isCancelled else { return }
            self.judgeDuplicates(for: report)
        }
    }

    // MARK: Already booked for collection

    /// Open collection requests found near this pin, under a **different** type.
    ///
    /// The portal scopes `nearBy` to the one type asked for, so these are
    /// invisible to everything else in the app: `prepare` never sees them and
    /// neither does the Review map. Somebody books a bulky-waste collection and
    /// puts the mattress out; a passer-by sees an abandoned mattress and files
    /// fly-tipping. Two type ids, one mattress, and the second report sends a
    /// worker to a job that is already on somebody's list.
    private(set) var bookedCollections: [NearByOccurrence] = []

    /// True when at least one of the lookups did not answer.
    ///
    /// Silence has to mean "nothing is booked", and it only does if the question
    /// was actually asked. Without this an empty result after a failed request
    /// reads as an all-clear.
    private(set) var collectionCheckFailed = false
    private(set) var isCheckingCollections = false

    /// Same place to within ~10 m, same type: the pin moves continuously under a
    /// finger and the answer does not change every metre.
    private struct CollectionKey: Hashable {
        let tipoId: Int
        let x: Int
        let y: Int

        init(tipoId: Int, at point: PtTm06) {
            self.tipoId = tipoId
            x = Int((point.x / 10).rounded())
            y = Int((point.y / 10).rounded())
        }
    }

    private var collectionCache: [CollectionKey: RelatedSearch] = [:]

    /// The one thing in this app that spends requests on the user's behalf
    /// without being asked.
    ///
    /// It is limited to `.collectedByRequest` on purpose. Those are the reports
    /// that mean *this is already handled, filing wastes a trip* — the case
    /// where the person most in need of the warning is the one who would never
    /// think to go looking for it. Merely similar types are an offer on the
    /// Browse screen instead, where nobody is standing in the street.
    ///
    /// Capped at `Taxonomy.maxRelatedLookups` and cached per type and place, so
    /// dragging the pin around the same corner does not re-buy the answer.
    private func checkForBookedCollections(for report: PreparedReport) async {
        let related = Taxonomy.bundled.related(to: report.type, matching: .collectedByRequest)
        guard !related.isEmpty else {
            clearCollectionCheck()
            return
        }

        let key = CollectionKey(tipoId: report.type.id, at: report.location.point)
        if let hit = collectionCache[key] {
            apply(hit)
            return
        }

        isCheckingCollections = true
        defer { isCheckingCollections = false }

        guard
            let search = try? await Geo.nearBy(
                client,
                around: report.location.coordinate,
                tipoIds: related.map(\.id)
            )
        else {
            // A projection failure. Everything else is already folded into
            // `RelatedSearch.failed`.
            clearCollectionCheck()
            collectionCheckFailed = true
            return
        }

        guard !Task.isCancelled else { return }
        // Only complete answers are cached. Caching a partial one would turn a
        // moment's bad network into a warning that stays missing for as long as
        // the screen is open.
        if search.isComplete { collectionCache[key] = search }
        apply(search)
    }

    private func apply(_ search: RelatedSearch) {
        // Resolved requests are not a reason to stay quiet: if the collection
        // has already happened and the thing is still on the pavement, that is
        // exactly when somebody *should* report it.
        bookedCollections = search.found.filter {
            !$0.isResolved && $0.distance <= Submitter.duplicateRadiusMetres
        }
        collectionCheckFailed = !search.isComplete
    }

    private func clearCollectionCheck() {
        bookedCollections = []
        collectionCheckFailed = false
    }

    // MARK: Duplicate judgement

    /// Nearby reports the model thinks describe the same problem, and why.
    ///
    /// Separate from `PreparedReport.possibleDuplicates`, which is the
    /// deterministic check: same type id, within 50 m, still open. That one
    /// cannot see a pothole filed under two different type ids; this one reads
    /// the descriptions and can.
    private(set) var flaggedDuplicates: [NearByOccurrence] = []
    private(set) var duplicateNote: String?

    private var judgeTask: Task<Void, Never>?
    private var lastJudgedKey: String?

    /// The second model call, made only when there is something to compare
    /// against.
    ///
    /// It adds no load on the municipal service — `prepare` fetched the
    /// same-type reports and `checkForBookedCollections` has already fetched the
    /// rest — but it is a paid call, and `resolve` runs every time the pin moves.
    /// Hence the key: dragging the pin around the same few reports re-uses the
    /// verdict instead of re-buying it.
    ///
    /// It runs **after** the cross-type look, on the union of both, which is the
    /// first time this call has ever had more than one type to read. Its whole
    /// reason for existing is that the same problem gets filed under different
    /// ids; until there was a second id in the list it could not have found one.
    private func judgeDuplicates(for report: PreparedReport) {
        // Merged nearest-first rather than same-type-first: eight is what the
        // prompt carries, and a collection request 8 m away earns its slot
        // ahead of a litter report at 90.
        //
        // `duplicateCandidates` also drops the resolved ones, which matters
        // most here: the deterministic layers dropped them already, so a closed
        // report reaching this list was the only way one could still surface
        // under "possibly already reported" — a warning against filing, made
        // about a report the council has already closed.
        let nearBy = (report.location.nearBy + bookedCollections)
            .duplicateCandidates(limit: 8)

        guard hasAPIKey, !nearBy.isEmpty else {
            clearDuplicateJudgement()
            return
        }

        let key = "\(report.type.id)|\(descricao)|\(nearBy.map(\.id).sorted())"
        guard key != lastJudgedKey else { return }
        lastJudgedKey = key

        judgeTask?.cancel()
        judgeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            do {
                let verdict = try await self.drafter.judgeDuplicates(
                    descricao: self.descricao,
                    type: report.type,
                    address: report.location.address,
                    nearBy: nearBy
                )
                guard !Task.isCancelled else { return }
                self.flaggedDuplicates = verdict.matches.compactMap { position in
                    nearBy.indices.contains(position - 1) ? nearBy[position - 1] : nil
                }
                self.duplicateNote = self.flaggedDuplicates.isEmpty ? nil : verdict.reason
            } catch {
                // A failed duplicate check is not a reason to block anything.
                // The deterministic 50 m check still ran, the nearby reports
                // are on the Review screen either way, and the person standing
                // in the street can still file.
                guard !Task.isCancelled else { return }
                self.lastJudgedKey = nil
                self.flaggedDuplicates = []
                self.duplicateNote = nil
            }
        }
    }

    private func clearDuplicateJudgement() {
        judgeTask?.cancel()
        lastJudgedKey = nil
        flaggedDuplicates = []
        duplicateNote = nil
    }

    // MARK: Submit — the irreversible bit

    /// Called only from the Review screen's confirm action.
    ///
    /// The `ReviewConfirmation` is bound to this exact prepared report: if the
    /// user has since dragged the pin or edited the text, `prepare` ran again,
    /// the id changed, and `ReparaCore` refuses the submission rather than
    /// filing something the user did not read.
    func submitReviewedReport() async {
        guard let report = prepared else { return }
        busyMessage = submitMode == .live ? "Filing…" : "Building the payload…"
        defer { busyMessage = nil }

        do {
            let outcome = try await submitter.submit(
                report,
                confirmation: ReviewConfirmation(userConfirmed: report),
                mode: submitMode
            )
            switch outcome {
            case let .filed(result):
                stage = .filed(result)
            case let .dryRun(payload, _, multipartBytes):
                stage = .dryRan(payload: payload, bytes: multipartBytes)
            }
            error = nil
        } catch {
            self.error = describe(error)
        }
    }

    // MARK: Reset

    func startOver() {
        resolveTask?.cancel()
        clearDuplicateJudgement()
        clearCollectionCheck()
        photo = nil
        photoForModel = nil
        userText = ""
        type = nil
        descricao = ""
        referencia = ""
        draftNotes = nil
        draftConfidence = nil
        prepared = nil
        pin = location.coordinate
        error = nil
        stage = .capture
    }

    // MARK: Errors

    private func describe(_ error: any Error) -> String {
        switch error {
        case let error as PortalError: return error.description
        case let error as SubmitError: return error.description
        case let error as TaxonomyError: return error.description
        case let error as ProjectionError: return error.description
        case let error as ModelError: return error.description
        case let error as Drafter.DrafterError: return error.description
        default: return error.localizedDescription
        }
    }
}
