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
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @State private var showingTypePicker = false
    @State private var showingConfirmation = false

    var body: some View {
        @Bindable var model = model

        Form {
            mapSection
            addressSection
            typeSection
            descriptionSection
            duplicatesSection
            photoSection
            submitSection
        }
        .sheet(isPresented: $showingTypePicker) {
            TypePickerView(selection: $model.type) { model.resolve() }
        }
        .confirmationDialog(
            model.submitMode == .live
                ? "File this report with Câmara Municipal de Lisboa?"
                : "Build the payload without sending it?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                model.submitMode == .live ? "File it" : "Dry run",
                role: model.submitMode == .live ? .destructive : nil
            ) {
                Task { await model.submitReviewedReport() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if model.submitMode == .live {
                Text("A council worker will be dispatched to \(model.prepared?.location.address ?? "this address"). This cannot be undone from the app.")
            }
        }
    }

    // MARK: Map

    @ViewBuilder private var mapSection: some View {
        @Bindable var model = model

        if let pin = Binding($model.pin) {
            Section {
                PinMap(
                    coordinate: pin,
                    isResolving: model.isResolving,
                    neighbours: model.prepared?.location.nearBy ?? [],
                    onSettle: { model.resolve() }
                )
                .frame(height: 240)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("Drag the map so the pin sits on the problem — the building frontage, not where you are standing. The address updates when you let go.")
            }
        }
    }

    // MARK: Address

    @ViewBuilder private var addressSection: some View {
        Section {
            if let prepared = model.prepared {
                VStack(alignment: .leading, spacing: 4) {
                    Text(prepared.location.address)
                        .font(.headline)
                    Text(prepared.location.freguesia)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)

                if prepared.location.isStreetMatch {
                    Label {
                        Text(prepared.location.warning ?? "")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                }
            } else if model.isResolving {
                HStack {
                    ProgressView()
                    Text("Looking up the address…").foregroundStyle(.secondary)
                }
            } else if let error = model.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Where")
        } footer: {
            Text("This is the address the council navigates to. It is the cheapest possible check against sending someone to the wrong door.")
        }
    }

    // MARK: Type

    @ViewBuilder private var typeSection: some View {
        Section {
            Button { showingTypePicker = true } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.type?.descricao ?? "Choose a report type")
                            .foregroundStyle(model.type == nil ? .secondary : .primary)
                        if let type = model.type {
                            Text(type.area)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            .tint(.primary)

            if let confidence = model.draftConfidence, confidence != .high {
                Label(
                    "\(model.providerName) was \(confidence.rawValue) confidence about this type — worth a second look.",
                    systemImage: "questionmark.circle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        } header: {
            Text("Type")
        } footer: {
            Text("The type decides which council department gets this. Several are worded alike across departments.")
        }
    }

    // MARK: Description

    @ViewBuilder private var descriptionSection: some View {
        @Bindable var model = model

        Section {
            TextField("O que está errado?", text: $model.descricao, axis: .vertical)
                .lineLimit(4...12)
                .onChange(of: model.descricao) { _, _ in model.resolve() }

            HStack {
                Spacer()
                Text("\(model.descricao.count) / \(Submitter.maxDescription)")
                    .font(.caption2)
                    .foregroundStyle(
                        model.descricao.count > Submitter.maxDescription ? .red : .secondary)
            }

            if let notes = model.draftNotes {
                Label(notes, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("What the council will read")
        } footer: {
            Text("Portuguese, because a council worker reads it. Edit it freely — this exact text is what gets sent.")
        }
    }

    // MARK: Duplicates

    /// Two sources, deliberately merged into one section: the deterministic
    /// same-type-within-50 m check from `ReparaCore`, and anything the model
    /// flagged after reading the descriptions. The second catches the same
    /// problem filed under a different type, which the first cannot see.
    @ViewBuilder private var duplicatesSection: some View {
        let geometric = model.prepared?.possibleDuplicates ?? []
        let flagged = model.flaggedDuplicates.filter { candidate in
            !geometric.contains { $0.id == candidate.id }
        }

        if !geometric.isEmpty || !flagged.isEmpty {
            Section {
                ForEach(geometric) { duplicate in
                    duplicateRow(duplicate, note: nil)
                }
                ForEach(flagged) { duplicate in
                    duplicateRow(duplicate, note: model.duplicateNote)
                }
            } header: {
                Label("Possibly already reported", systemImage: "exclamationmark.2")
                    .foregroundStyle(.orange)
            } footer: {
                Text("A duplicate wastes a worker's trip — check whether one of these is already your problem. Open reports of the same type within 50 m are listed automatically; \(model.providerName) also reads the descriptions, because the same problem is often filed under a different type.")
            }
        }
    }

    private func duplicateRow(_ duplicate: NearByOccurrence, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(duplicate.numero).font(.subheadline.monospaced())
            if let text = duplicate.descricao, !text.isEmpty {
                Text(text).font(.footnote)
            }
            Text("\(Int(duplicate.distance)) m away · \(duplicate.estado)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let note, !note.isEmpty {
                Label(note, systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: Photo

    @ViewBuilder private var photoSection: some View {
        if let data = model.photo, let image = UIImage(data: data) {
            Section("Photo") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(.rect(cornerRadius: 8))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Submit

    @ViewBuilder private var submitSection: some View {
        Section {
            if model.submitMode == .live {
                Label("Live — this will file a real report", systemImage: "exclamationmark.octagon.fill")
                    .font(.footnote.bold())
                    .foregroundStyle(.red)
            } else {
                Label("Dry run — nothing will be sent", systemImage: "checkmark.shield")
                    .font(.footnote.bold())
                    .foregroundStyle(.green)
            }

            Button {
                showingConfirmation = true
            } label: {
                HStack {
                    if model.busyMessage != nil { ProgressView().padding(.trailing, 4) }
                    Text(model.submitMode == .live ? "File this report" : "Build the payload")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.submitMode == .live ? .red : .accentColor)
            .disabled(!canSubmit)

            Button("Start over", role: .destructive) { model.startOver() }
                .frame(maxWidth: .infinity)
        } footer: {
            if model.account == nil {
                Text("Not signed in to Na Minha Rua LX. Sign in from Settings before filing.")
                    .foregroundStyle(.orange)
            } else if let prepared = model.prepared, !prepared.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(prepared.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.circle")
                    }
                }
                .foregroundStyle(.orange)
            }
        }
    }

    private var canSubmit: Bool {
        model.prepared != nil
            && model.busyMessage == nil
            && !model.isResolving
            && !model.descricao.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.descricao.count <= Submitter.maxDescription
            && (model.account != nil || model.submitMode == .dryRun)
    }
}
