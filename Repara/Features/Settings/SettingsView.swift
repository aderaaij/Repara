import ReparaCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""
    @State private var provider = ModelSettings.provider
    @State private var savedKey = ModelSettings.hasAPIKey
    @State private var draftModel = ""
    @State private var judgeModel = ""

    var body: some View {
        NavigationStack {
            Form {
                portalSection
                providerSection
                modelSection
                submitModeSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveModelOverrides()
                        dismiss()
                    }
                }
            }
            .onAppear(perform: loadModelOverrides)
            // Swiping the sheet away is not "cancel" — it is how most people
            // close it, and a model id typed but not submitted would otherwise
            // be silently discarded.
            .onDisappear(perform: saveModelOverrides)
        }
    }

    // MARK: Portal

    /// Signed-in only. Settings is behind the gate, so there is no signed-out
    /// state to render here — signing in happens on the welcome screen, and
    /// signing out closes this sheet and hands back to it.
    @ViewBuilder private var portalSection: some View {
        Section {
            if let account = model.account {
                LabeledContent("Signed in as", value: account.nome)
                LabeledContent("Account", value: account.email)
                Button("Sign out", role: .destructive) {
                    Task { await model.signOut() }
                }
            }
        } header: {
            Text("Na Minha Rua LX")
        } footer: {
            Text("Reports are filed under this account, so the council knows who reported the problem and can reach you about it. Credentials are stored in the Keychain. Signing out discards the report in progress and returns to the welcome screen.")
        }
    }

    // MARK: Provider

    /// The drafting and duplicate-checking calls are the same narrow job
    /// whoever answers them, so which service that is belongs to the user.
    /// A key is stored per provider, so switching back does not mean finding
    /// the key again.
    @ViewBuilder private var providerSection: some View {
        Section {
            Picker("Provider", selection: $provider) {
                ForEach(ModelProviderID.allCases) { candidate in
                    Text(candidate.displayName).tag(candidate)
                }
            }
            .onChange(of: provider) { previous, selected in
                // The model fields still hold the previous provider's text;
                // banking it first is what makes switching back and forth
                // lossless.
                ModelSettings.setDraftModel(draftModel, for: previous)
                ModelSettings.setJudgeModel(judgeModel, for: previous)

                ModelSettings.provider = selected
                // Every field below is per-provider, so none of it survives
                // the switch.
                savedKey = ModelSettings.hasAPIKey
                apiKey = ""
                loadModelOverrides()
            }

            if savedKey {
                LabeledContent("API key", value: "Stored in Keychain")
                Button("Remove key", role: .destructive) {
                    try? Keychain.set(nil, for: provider.keychainKey)
                    savedKey = false
                }
            } else {
                SecureField(provider.apiKeyPlaceholder, text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save key") {
                    try? Keychain.set(apiKey, for: provider.keychainKey)
                    savedKey = ModelSettings.hasAPIKey
                    apiKey = ""
                }
                .disabled(apiKey.isEmpty)
            }
        } header: {
            Text("Drafting")
        } footer: {
            Text("""
                Sent to \(provider.host): the downscaled photo, what you typed, the report-type \
                list, and — for the duplicate check — the type, status, distance and public \
                description of nearby reports. Never the name, email or reference number of \
                whoever filed one of those.

                The key cannot be shipped inside the app — anyone could extract it from the \
                bundle. Enter it once and it stays in the Keychain, which also keeps this app \
                free of any server of its own.
                """)
        }
    }

    // MARK: Models

    /// Free text rather than a menu because model names change faster than
    /// this app ships. A default that goes stale has to be something you can
    /// fix here, not a reason to wait for a release.
    @ViewBuilder private var modelSection: some View {
        Section {
            LabeledContent("Drafting") {
                TextField(provider.defaultDraftModel, text: $draftModel)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(saveModelOverrides)
            }
            LabeledContent("Duplicate check") {
                TextField(provider.defaultJudgeModel, text: $judgeModel)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(saveModelOverrides)
            }
        } header: {
            Text("\(provider.displayName) models")
        } footer: {
            Text("""
                Leave these blank for the defaults shown. Drafting picks one of \
                \(Taxonomy.bundled.types.count) report types from a photograph and routes the \
                report to a council department, so it uses the stronger model; the duplicate \
                check only compares a few sentences against the reports already nearby.
                """)
        }
    }

    private func saveModelOverrides() {
        ModelSettings.setDraftModel(draftModel, for: provider)
        ModelSettings.setJudgeModel(judgeModel, for: provider)
    }

    private func loadModelOverrides() {
        // Blank when unset, so the placeholder shows the default rather than
        // baking a stale id into the field the moment Settings is opened.
        draftModel = ModelSettings.draftModel(for: provider) == provider.defaultDraftModel
            ? "" : ModelSettings.draftModel(for: provider)
        judgeModel = ModelSettings.judgeModel(for: provider) == provider.defaultJudgeModel
            ? "" : ModelSettings.judgeModel(for: provider)
    }

    // MARK: Submit mode

    @ViewBuilder private var submitModeSection: some View {
        @Bindable var model = model

        Section {
            Toggle(
                "File reports for real",
                isOn: Binding(
                    get: { model.submitMode == .live },
                    set: { model.submitMode = $0 ? .live : .dryRun }
                )
            )
            .tint(.red)
        } header: {
            Text("Submission")
        } footer: {
            Text("""
                Off, Repara builds the exact payload and shows it to you without sending \
                anything. On, filing creates a real work order: a council worker reads it and \
                is dispatched, and there is no way to withdraw it from the app.

                Do not test by filing. Every test submission is a real dispatch.
                """)
        }
    }

    // MARK: About

    @ViewBuilder private var aboutSection: some View {
        Section {
            NavigationLink {
                TypeCatalogueView()
            } label: {
                LabeledContent("Report types", value: "\(Taxonomy.bundled.types.count)")
            }
            LabeledContent(
                "Projection self-check",
                value: String(format: "%.4f mm drift", Projection.selfCheckDriftMetres * 1000))
        } header: {
            Text("About")
        } footer: {
            Text("""
                Coordinates are projected to EPSG:3763 on this phone. The portal's own map \
                picker delegates that to a server call which applies a spurious datum shift and \
                lands 114 m away — that bug is why this app exists, so the projection is \
                checked against a known reference point at launch and again before every \
                submission.
                """)
        }
    }
}
