import ReparaCore
import SwiftUI

/// **THE GATE.**
///
/// Submitting files a real work order with a municipal government. A council
/// worker reads it and is dispatched. There is no undo, no delete endpoint, and
/// a wrong or duplicate report wastes public money.
///
/// So this screen shows, before anything can be filed: the resolved street
/// address, the freguesia, the exact Portuguese text that will be sent, the
/// photo, and any open reports of the same type within 50 m. Every one of them
/// is editable or draggable, and every edit re-resolves and invalidates the
/// previous confirmation.
///
/// The shape of it, in reading order:
///
/// 1. **One card that is both the verdict and the loudest caution.** What
///    stands in the way, in that caution's own tier signature, with the address
///    and the department under a hairline inside the same card. Learning the
///    mode after six scrolls is how somebody files a real report thinking they
///    were dry-running — but a summary card stacked on top of a warning card
///    had nothing of its own to say and just said the warning twice.
/// 2. **The remaining cautions**, each in the tier that names what it wants —
///    see `CautionTier`. Ordered stop → decide → pending → unverified →
///    heads-up; whichever of them came first is up in the card above.
/// 3. **The Portuguese, as the hero.** It is what a council worker reads, so it
///    is the largest text on the screen and it is also the scroll gate: the
///    submit button stays inert until this block has passed the fold.
/// 4. **Map, type and photo as one-line summaries**, expanding in place. By the
///    time this screen exists the pin has been placed; the map is confirmation,
///    not a control.
///
/// The counted checks are **never a gate**. Only having scrolled past the
/// Portuguese is, because that is a fact about the user rather than about the
/// network.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @State private var showingTypePicker = false
    @State private var showingConfirmation = false
    @State private var whereExpanded = false
    @State private var photoExpanded = false
    @State private var hasReadBody = false
    /// The warned-about report being looked at, from either caution card.
    ///
    /// Costs the council nothing to open: everything on the sheet came back
    /// with the lookups that produced the warning. Only its photographs are a
    /// further request, and only once somebody has decided to look.
    @State private var inspected: NearByOccurrence?
    @FocusState private var editingBody: Bool

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(spacing: 14) {
                verdictSection
                if let error = model.error { errorCard(error) }
                cautions
                descriptionBlock
                detailsCard
                startOver
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Repara.canvas)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { submitBar }
        .sheet(isPresented: $showingTypePicker) {
            TypePickerView(selection: $model.type) { model.resolve() }
        }
        .sheet(isPresented: $showingConfirmation) { confirmationSheet }
        // Opened against the pin, so the sheet can draw both points and say how
        // far apart they are — the question a caution card is actually asking.
        .sheet(item: $inspected) { report in
            OccurrenceSheet(report: report, comparedTo: model.pin)
        }
    }

    // MARK: The verdict

    /// The one thing standing in the way, if anything is.
    ///
    /// Whichever caution this names is drawn **as** the verdict card and not
    /// again in the stack below it. A separate summary card had nothing of its
    /// own to say: every branch of it was a paraphrase of the card immediately
    /// underneath, and once a claim exists in two places the two drift — the
    /// booked caution learned to soften past 25 m while the summary above it
    /// went on telling.
    ///
    /// The order is the stack's order, so the card that gets promoted is the
    /// one that would have been on top anyway: stop → decide → pending →
    /// unverified. Heads-up items never qualify — they are worth fixing, not
    /// worth a verdict.
    private enum Concern {
        case booked, duplicates, pending, unverified
    }

    private var leadingConcern: Concern? {
        if !model.openBookedCollections.isEmpty { return .booked }
        if model.duplicatesNeedAnswer { return .duplicates }
        if model.isCheckingCollections { return .pending }
        if model.collectionCheckFailed { return .unverified }
        return nil
    }

    /// The signature the top card wears. `nil` is the clear card: glass, no
    /// tier, because nothing outside `CautionTier` may pick a warning colour
    /// and "nothing stands in the way" is not a warning.
    private var verdictTier: CautionTier? {
        switch leadingConcern {
        case .booked: model.bookedCollectionIsAtThisSpot ? .stop : .decide
        case .duplicates: .decide
        case .pending: .pending
        case .unverified: .unverified
        case nil: nil
        }
    }

    private var verdictSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Before this is filed")
                .font(.footnote.weight(.semibold))
                .kerning(0.2)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            verdictCard
        }
    }

    @ViewBuilder private var verdictCard: some View {
        let facts = AnyView(verdictFacts(onFilled: verdictTier == .stop))
        switch leadingConcern {
        case .booked: bookedCaution(footer: facts)
        case .duplicates: duplicateCaution(footer: facts)
        case .pending: pendingCaution(footer: facts)
        case .unverified: unverifiedCaution(footer: facts)
        case nil: clearVerdictCard
        }
    }

    /// Nothing to warn about, so no tier and no signature — glass, and a
    /// sentence assembled from two facts rather than asserted, so that it
    /// cannot claim "nothing nearby" on a screen that is showing something
    /// nearby.
    private var clearVerdictCard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(clearVerdict.title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text(clearVerdict.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)

            verdictFacts(onFilled: false)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: Repara.Radius.hero, style: .continuous))
    }

    private var clearVerdict: (title: String, detail: String) {
        if model.prepared == nil {
            return (
                model.isResolving ? "Working out where this is" : "Not ready to file",
                model.isResolving
                    ? "Asking the council's server which address the pin lands on."
                    : "Pick a report type and place the pin before this can be prepared."
            )
        }
        let street = model.prepared?.location.isStreetMatch == true
        return (
            "Nothing stands in the way",
            (street
                ? "The pin matched a street rather than a building."
                : "The address resolved to a building.")
                + " "
                + (model.surfacedDuplicates.isEmpty
                    ? "No open report of this type is nearby."
                    : "You have ruled out the nearby reports.")
        )
    }

    /// Where this is going and which department gets it — inside whichever card
    /// is on top, because both facts have to be above the fold and neither of
    /// them was ever worth a card of its own.
    private func verdictFacts(onFilled: Bool) -> some View {
        let divider = onFilled ? Color.white.opacity(0.28) : Repara.hairline
        return VStack(spacing: 0) {
            Rectangle().fill(divider).frame(height: 0.5)
            HStack(spacing: 0) {
                verdictFact("Address", model.prepared?.location.address ?? "—", onFilled: onFilled)
                Rectangle().fill(divider).frame(width: 0.5)
                verdictFact("Department", model.type?.area ?? "—", onFilled: onFilled)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func verdictFact(_ label: String, _ value: String, onFilled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(
                    onFilled
                        ? AnyShapeStyle(Color.white.opacity(0.8))
                        : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(
                    onFilled ? AnyShapeStyle(Repara.onStop) : AnyShapeStyle(Color.primary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func errorCard(_ error: String) -> some View {
        CautionCard(
            .unverified,
            title: "Something did not work",
            message: error,
            systemImage: "exclamationmark.triangle"
        )
    }

    // MARK: The cautions

    /// Everything the verdict card did not already say. The promoted one is
    /// skipped here rather than dimmed or shortened: it is on the screen, at
    /// full strength, at the top.
    @ViewBuilder private var cautions: some View {
        if leadingConcern != .booked { bookedCaution() }
        if leadingConcern != .duplicates { duplicateCaution() }
        if model.isCheckingCollections, leadingConcern != .pending { pendingCaution() }
        if model.collectionCheckFailed, leadingConcern != .unverified { unverifiedCaution() }
        streetCaution
        photoCaution
        signedOutCaution
    }

    /// Not a duplicate warning, and deliberately placed above one.
    ///
    /// A duplicate says "somebody else has already told them". This says "this
    /// is already scheduled, and a report on top of it sends a second worker to
    /// a job on somebody's list" — a reason not to file at all, not a reason to
    /// check. It is the one tier that fills its whole surface.
    ///
    /// No model is involved in the claim: the type ids are known to be
    /// collection requests from the bundled map, so it says what it says on the
    /// strength of the taxonomy alone.
    @ViewBuilder private func bookedCaution(footer: AnyView? = nil) -> some View {
        let booked = model.openBookedCollections
        if let nearest = booked.first {
            let onTheSpot = model.bookedCollectionIsAtThisSpot
            let tier: CautionTier = onTheSpot ? .stop : .decide
            let place = metres(nearest.distance).map { "\($0) from your pin" } ?? "near your pin"
            CautionCard(
                tier,
                title: onTheSpot
                    ? "Already booked — don't file this"
                    : "This may already be booked",
                message: onTheSpot
                    ? "A collection request \(place) is scheduled and not yet done. Filing sends a "
                        + "second worker to a job that is already on the list."
                    : "A collection request is scheduled \(place) and not yet done. That is far "
                        + "enough to be a different pile — open it and see before you decide.",
                systemImage: onTheSpot ? "exclamationmark.octagon.fill" : "exclamationmark.triangle",
                footer: footer
            ) {
                VStack(spacing: 8) {
                    ForEach(booked) { report in
                        QuotedReport(
                            tipo: report.tipo,
                            text: report.descricao,
                            footnote:
                                "\(distancePhrase(report.distance)) · \(report.estado)",
                            onFilledSurface: onTheSpot,
                            onOpen: { inspected = report }
                        )
                    }
                }
                // "Different problem" is the dissent, and until now it was the
                // only one of the two answers somebody could not check first.
                // Opening the report is what makes that chip an informed
                // choice rather than a guess against a red card.
                HStack(spacing: 8) {
                    AnswerChip.agreeing("Don't file it", tier) { model.startOver() }
                    AnswerChip.dissenting("Different problem", tier) {
                        model.dismissBookedWarning()
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    /// Two sources, one card: the deterministic same-type-within-50 m check from
    /// `ReparaCore`, and anything the model flagged after reading the
    /// descriptions. The second catches the same problem filed under a
    /// different type, which the first cannot see.
    ///
    /// Both are open reports only. A report the council has closed is not an
    /// argument against filing — if the thing is still there, it is an argument
    /// for it.
    ///
    /// It ends in two answers rather than an acknowledgement. "No — mine is new"
    /// is a fact the screen can then stop asking about; a warning you can only
    /// nod at teaches nobody anything and gets skimmed past by the third report.
    @ViewBuilder private func duplicateCaution(footer: AnyView? = nil) -> some View {
        let duplicates = model.surfacedDuplicates
        if !duplicates.isEmpty {
            CautionCard(
                .decide,
                title: "Is this the same problem?",
                message: duplicateMessage(duplicates),
                systemImage: "exclamationmark.triangle",
                footer: footer
            ) {
                VStack(spacing: 8) {
                    ForEach(duplicates) { report in
                        QuotedReport(
                            numero: report.numero,
                            text: report.descricao,
                            footnote: duplicateFootnote(report),
                            onOpen: { inspected = report }
                        )
                    }
                }

                if let note = model.duplicateNote, !note.isEmpty {
                    Label(note, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Repara.amberInk)
                }

                if model.duplicatesNeedAnswer {
                    HStack(spacing: 8) {
                        AnswerChip.agreeing("Yes — it's this", .decide) { model.startOver() }
                        AnswerChip.dissenting("No — mine is new", .decide) {
                            model.answerDuplicatesAsNew()
                        }
                    }
                    .padding(.top, 2)
                } else {
                    AnsweredNote(text: "Checked — you said yours is a new problem")
                        .padding(.top, 2)
                }
            }
        }
    }

    private func duplicateMessage(_ duplicates: [NearByOccurrence]) -> String {
        let sameType = model.prepared?.possibleDuplicates.count ?? 0
        // `min(by:)` over a list that may carry `.nan` distances: NaN comparisons
        // are always false, so this settles on *some* element rather than
        // trapping, and `distancePhrase` says "nearby" if that one is unfilled.
        let nearest = duplicates.min { $0.distance < $1.distance }
        let distance = nearest.map { distancePhrase($0.distance) } ?? "nearby"
        let opening =
            duplicates.count == 1
            ? "One open report sits \(distance)."
            : "\(duplicates.count) open reports are nearby, the closest \(distance)."
        let source =
            sameType == duplicates.count
            ? "Same type, within \(Int(Submitter.duplicateRadiusMetres)) m."
            : "\(model.providerName) read the descriptions of these and of anything open under a "
                + "related type, because the same problem often gets filed under a different one."
        return "\(opening) \(source) A duplicate wastes a worker's trip — answer this and the "
            + "check clears."
    }

    private func duplicateFootnote(_ report: NearByOccurrence) -> String {
        let sameType = model.prepared?.possibleDuplicates.contains { $0.id == report.id } == true
        return "\(distancePhrase(report.distance)) · \(report.estado) · "
            + (sameType ? "same type" : report.tipo)
    }

    /// Named rather than silent: this appears a second after the rest of the
    /// screen, and an unexplained warning that pops in later reads as the app
    /// having changed its mind.
    private func pendingCaution(footer: AnyView? = nil) -> some View {
        CautionCard(
            .pending,
            title: "Still checking",
            message:
                "Asking whether a collection is already booked here. No answer yet — that is not "
                + "an all-clear.",
            systemImage: "clock",
            footer: footer
        ) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for the council's server")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    /// "Nothing is booked" and "we could not find out" must not look the same,
    /// and the honest version of the second is to say so — in the loudest
    /// non-red signature in the set, with no tick and nothing green anywhere
    /// near it.
    private func unverifiedCaution(footer: AnyView? = nil) -> some View {
        CautionCard(
            .unverified,
            title: "Not checked — not cleared",
            message:
                "The council's server did not answer, so Repara does not know whether a collection "
                + "is already booked here. It may be. This is not the same as nothing being here.",
            systemImage: "wifi.exclamationmark",
            footer: footer
        ) {
            HStack(spacing: 8) {
                Button {
                    Task { await model.retryCollectionCheck() }
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Repara.onInk)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(Repara.unknownInk, in: .capsule)
                }
                .buttonStyle(.plain)

                // A label, not a button. Filing is not blocked by any of these
                // checks, so there is nothing here to press — saying so is the
                // point, and a chip that "allowed" it would imply the rest do
                // block.
                Text("Filing is not blocked")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(.quaternary, in: .capsule)
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder private var streetCaution: some View {
        if model.prepared?.location.isStreetMatch == true {
            CautionCard(
                .headsUp,
                title: "The pin matched a street, not a building",
                message:
                    "The report will carry no house number. Drag the pin onto the frontage and the "
                    + "address resolves to a door — that is what a council worker navigates by.",
                systemImage: "mappin.and.ellipse"
            ) {
                Button("Open the map") {
                    withAnimation(.snappy) { whereExpanded = true }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Repara.headsUpInk)
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder private var photoCaution: some View {
        if model.prepared?.photos.isEmpty == true {
            CautionCard(
                .headsUp,
                title: "No photo attached",
                message: "A photo is the evidence a council worker acts on.",
                systemImage: "camera"
            )
        }
    }

    @ViewBuilder private var signedOutCaution: some View {
        if model.account == nil {
            CautionCard(
                .headsUp,
                title: "Not signed in to Na Minha Rua LX",
                message: "A dry run works without a session. Filing does not — sign in from "
                    + "Settings first.",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
        }
    }

    // MARK: The Portuguese

    /// The hero, and the scroll gate.
    ///
    /// This exact text is what a council worker reads, which is the whole reason
    /// it is in Portuguese and the whole reason it is the largest thing on the
    /// screen — it used to be 17 pt inside a `TextField` that looked like every
    /// other row. Scrolling past it, or tapping into it, is what arms the submit
    /// button.
    private var descriptionBlock: some View {
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: 8) {
            Text("What the council will read").reparaSectionTitle()

            VStack(alignment: .leading, spacing: 0) {
                TextField("O que está errado?", text: $model.descricao, axis: .vertical)
                    .font(.system(size: 19))
                    .lineSpacing(4)
                    .focused($editingBody)
                    .onChange(of: model.descricao) { _, _ in model.resolve() }

                Rectangle().fill(Repara.hairline)
                    .frame(height: 0.5)
                    .padding(.vertical, 12)

                HStack {
                    Button {
                        editingBody = true
                    } label: {
                        Label("Edit the Portuguese", systemImage: "pencil")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Repara.ink)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("\(model.descricao.count) / \(Submitter.maxDescription)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(
                            model.descricao.count > Submitter.maxDescription
                                ? Repara.stop : .secondary)
                }
            }
            .padding(18)
            .background(Repara.card, in: .rect(cornerRadius: Repara.Radius.card, style: .continuous))

            if let notes = model.draftNotes {
                Label(notes, systemImage: "info.circle")
                    .reparaFootnote()
            }

            Text(
                "This is in Portuguese because a council worker reads it. You can edit every word."
            )
            .reparaFootnote()

            // The read mark. `onScrollVisibilityChange` fires on appear too, so a
            // report short enough to fit without scrolling arms the button
            // immediately rather than deadlocking it.
            Color.clear
                .frame(height: 2)
                .onScrollVisibilityChange(threshold: 0.01) { visible in
                    if visible { hasReadBody = true }
                }
        }
        .onChange(of: editingBody) { _, editing in
            // Typing in it is a stronger proof of having read it than scrolling
            // past it, and it is also the fallback if the mark never resolves.
            if editing { hasReadBody = true }
        }
    }

    // MARK: Where, type, photo

    /// One card, three collapsed rows. Each expands in place; none of them is
    /// the first thing on the screen any more.
    private var detailsCard: some View {
        @Bindable var model = model

        return CardGroup {
            DisclosureRow(
                systemImage: "mappin.and.ellipse",
                title: model.prepared?.location.address ?? "Placing the pin…",
                subtitle: whereSubtitle,
                isExpanded: $whereExpanded
            ) {
                if let pin = Binding($model.pin) {
                    ZStack(alignment: .bottom) {
                        PinMap(
                            coordinate: pin,
                            isResolving: model.isResolving,
                            // Booked collections too: one sitting on the same
                            // doorway as the pin is the clearest possible
                            // version of "that is the thing you are about to
                            // report".
                            neighbours: (model.prepared?.location.nearBy ?? [])
                                + model.bookedCollections,
                            onSettle: { model.resolve() }
                        )
                        .frame(height: 220)

                        Text("Drag the map — the pin marks the frontage")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                            .glassEffect(.regular, in: .capsule)
                            .padding(.bottom, 12)
                    }
                    .overlay(alignment: .top) {
                        Rectangle().fill(Repara.hairline).frame(height: 0.5)
                    }
                }
            }

            RowDivider()

            PushRow(
                systemImage: "tag",
                title: model.type?.descricao ?? "Choose a report type",
                subtitle: typeSubtitle
            ) {
                showingTypePicker = true
            }

            if let data = model.photo, let image = UIImage(data: data) {
                RowDivider()
                DisclosureRow(
                    systemImage: "photo",
                    title: "1 photo attached",
                    subtitle: "Full resolution · \(data.count.formatted(.byteCount(style: .file)))",
                    isExpanded: $photoExpanded
                ) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(.rect(cornerRadius: 14))
                        .padding([.horizontal, .bottom], 16)
                }
            }
        }
    }

    private var whereSubtitle: String {
        guard let location = model.prepared?.location else {
            return model.isResolving ? "Looking up the address…" : "Not resolved yet"
        }
        return
            "\(location.freguesia) · pin on the \(location.isStreetMatch ? "street" : "building")"
    }

    /// The area, and the model's own doubt when it had any.
    ///
    /// *Why* the type matters is said once, in the picker this row opens, rather
    /// than in a subtitle that wraps to two lines on every report.
    private var typeSubtitle: String {
        guard let type = model.type else { return "Decides which department is dispatched" }
        if let confidence = model.draftConfidence, confidence != .high {
            return "\(type.area) · drafted, \(confidence.rawValue) confidence"
        }
        return type.area
    }

    private var startOver: some View {
        Button("Start over", role: .destructive) { model.startOver() }
            .font(.body)
            .foregroundStyle(Repara.stop)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.top, 6)
    }

    // MARK: Submit

    /// A glass bar, 12 pt from the edges and inside the bottom third, so it is
    /// reachable one-handed while standing in the street.
    ///
    /// It states its own consequence — the mode is on the bar rather than in a
    /// footnote several scrolls above — and it counts the checks still open
    /// without ever refusing on their behalf.
    private var submitBar: some View {
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.submitMode == .live ? Repara.stop : Repara.done)
                        .frame(width: 8, height: 8)
                    Text(
                        model.submitMode == .live
                            ? "Live — this files for real" : "Dry run — nothing is sent"
                    )
                    .font(.footnote.weight(.medium))
                }
                Spacer()
                Text(checksLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)

            if canSubmit {
                Button {
                    showingConfirmation = true
                } label: {
                    HStack(spacing: 8) {
                        if model.busyMessage != nil { ProgressView().tint(.white) }
                        Text(submitLabel)
                    }
                }
                .buttonStyle(
                    model.submitMode == .live
                        ? InkButtonStyle(tint: Repara.stop, onTint: Repara.onStop, height: 60)
                        : InkButtonStyle(height: 60)
                )
                .transition(.opacity.combined(with: .offset(y: 8)))
            } else {
                VStack(spacing: 1) {
                    Text(submitLabel)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(blockedReason)
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(.quaternary, in: .capsule)
            }
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: Repara.Radius.bar, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .animation(.snappy(duration: 0.25), value: canSubmit)
    }

    private var submitLabel: String {
        model.submitMode == .live ? "File this report" : "Build the payload"
    }

    private var checksLine: String {
        let count = model.outstandingChecks
        if count == 0 { return "All checks answered" }
        return count == 1 ? "1 check outstanding" : "\(count) checks outstanding"
    }

    /// Everything that has to be true before the button exists at all, and the
    /// one thing that is about the user rather than the network.
    private var canSubmit: Bool {
        isReady && hasReadBody
    }

    private var isReady: Bool {
        model.prepared != nil
            && model.busyMessage == nil
            && !model.isResolving
            && !model.descricao.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.descricao.count <= Submitter.maxDescription
            && (model.account != nil || model.submitMode == .dryRun)
    }

    private var blockedReason: String {
        if !isReady { return "Not ready yet" }
        return "Scroll through the Portuguese text first"
    }

    // MARK: The point of no return

    /// The last thing before an irreversible act, and it restates the three
    /// facts somebody would regret getting wrong: where, what, and whether this
    /// is real.
    private var confirmationSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            model.submitMode == .live
                                ? "File this with Câmara Municipal de Lisboa?"
                                : "Build the payload without sending it?"
                        )
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)

                        Text(
                            model.submitMode == .live
                                ? "A council worker will be dispatched to "
                                    + "\(model.prepared?.location.address ?? "this address"). "
                                    + "This cannot be undone from the app."
                                : "Nothing leaves the phone. You get the exact bytes that would "
                                    + "have been posted."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    CardGroup {
                        summaryRow("Where", model.prepared?.location.address ?? "—")
                        RowDivider()
                        summaryRow("Type", model.type?.descricao ?? "—")
                        RowDivider()
                        summaryRow(
                            "Mode",
                            model.submitMode == .live
                                ? "Live — files for real" : "Dry run — nothing is sent")
                    }

                    Button(model.submitMode == .live ? "File it" : "Dry run") {
                        showingConfirmation = false
                        Task { await model.submitReviewedReport() }
                    }
                    .buttonStyle(
                        model.submitMode == .live
                            ? InkButtonStyle(tint: Repara.stop, onTint: Repara.onStop, height: 56)
                            : InkButtonStyle(height: 56)
                    )

                    Button("Keep reading") { showingConfirmation = false }
                        .font(.body)
                        .foregroundStyle(Repara.ink)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .padding(20)
            }
            .background(Repara.canvas)
        }
        .presentationDetents([.height(460), .large])
        .presentationDragIndicator(.visible)
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
