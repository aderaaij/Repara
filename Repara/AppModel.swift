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
    private let drafter = Drafter()

    init() {
        let client = PortalClient()
        self.client = client
        self.auth = Auth(client: client)
        self.submitter = Submitter(client: client)
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
    /// The downscaled copy that goes to Claude. Never sent to the portal.
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

    var hasAPIKey: Bool { Keychain.get(.claudeAPIKey)?.isEmpty == false }

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
        startOver()
    }

    // MARK: Capture → Draft

    func accept(image: UIImage) {
        photo = PhotoScaler.forCouncil(image)
        photoForModel = PhotoScaler.forModel(image)
        pin = location.coordinate
    }

    /// One Claude call: photo in, `{tipo_id, descricao}` out — both editable on
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

            self.isResolving = true
            defer { self.isResolving = false }
            do {
                self.prepared = try await self.submitter.prepare(
                    type: type,
                    at: pin,
                    descricao: body,
                    referencia: self.referencia,
                    photos: self.photo.map { [Photo(jpeg: $0)] } ?? []
                )
                self.error = nil
                if let prepared = self.prepared { self.judgeDuplicates(for: prepared) }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.prepared = nil
                self.error = self.describe(error)
                self.clearDuplicateJudgement()
            }
        }
    }

    // MARK: Duplicate judgement

    /// Nearby reports Claude thinks describe the same problem, and why.
    ///
    /// Separate from `PreparedReport.possibleDuplicates`, which is the
    /// deterministic check: same type id, within 50 m, still open. That one
    /// cannot see a pothole filed under two different type ids; this one reads
    /// the descriptions and can.
    private(set) var flaggedDuplicates: [NearByOccurrence] = []
    private(set) var duplicateNote: String?

    private var judgeTask: Task<Void, Never>?
    private var lastJudgedKey: String?

    /// The second Claude call, made only when there is something to compare
    /// against.
    ///
    /// It adds no load on the municipal service — `prepare` already fetched
    /// `nearBy` — but it is a paid call, and `resolve` runs every time the pin
    /// moves. Hence the key: dragging the pin around the same few reports
    /// re-uses the verdict instead of re-buying it.
    private func judgeDuplicates(for report: PreparedReport) {
        let nearBy = Array(report.location.nearBy.prefix(8))
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
        case let error as Drafter.DrafterError: return error.description
        default: return error.localizedDescription
        }
    }
}
