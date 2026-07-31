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
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue

    var body: some View {
        NavigationStack {
            Form {
                portalSection
                languageSection
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
    ///
    /// Why the account exists at all is said on that welcome screen, in front of
    /// somebody deciding whether to make one. Repeating it here left the two
    /// wordings to drift; this footer says only what the rows below it do.
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
            Text("Credentials are stored in the Keychain. Signing out discards the report in progress.")
        }
    }

    // MARK: Language

    /// Bound straight to the same key `LocalizedRoot` reads, so the app redraws
    /// in the new language as the picker closes — there is nothing to apply and
    /// no relaunch to sit through.
    ///
    /// The footer is the load-bearing part. Everything else in Settings changes
    /// what the user sees; this one is next to a report that goes to a council
    /// worker, and the answer to "does this translate my report" is no.
    @ViewBuilder private var languageSection: some View {
        Section {
            Picker("Language", selection: $language) {
                ForEach(AppLanguage.allCases) { candidate in
                    candidate.pickerLabel.tag(candidate.rawValue)
                }
            }
            // The app's own text follows `\.locale` and has already changed by
            // the time this runs. This is for the permission alerts, which iOS
            // draws from the bundle language — see `syncBundleLanguage`.
            .onChange(of: language) { _, selected in
                (AppLanguage(rawValue: selected) ?? .system).syncBundleLanguage()
            }
        } header: {
            Text("Language")
        } footer: {
            Text("""
                Changes the app, not the report. What you file is always European Portuguese, \
                because a council worker reads it — and you can edit every word of it before \
                anything is sent.
                """)
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

                Your key stays in the Keychain on this phone.
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
                Leave blank for the defaults shown. Drafting reads a photograph and picks one of \
                \(Taxonomy.bundled.types.count) types, so it uses the stronger model; the \
                duplicate check only compares a few sentences.
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

    /// The footer states the consequence and stops there.
    ///
    /// It used to end "Do not test by filing. Every test submission is a real
    /// dispatch." That is `CLAUDE.md`'s rule, and it is addressed to whoever is
    /// working on this app — somebody who turns this toggle on to report a
    /// mattress is not testing anything. It reads as an accusation to the one
    /// person on the screen who cannot be the intended audience.
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
                anything. On, filing creates a real work order: a council worker is dispatched, \
                and there is no way to withdraw it from the app.
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
                Coordinates are projected to EPSG:3763 on this phone rather than by the portal's \
                server, which lands 114 m off. Checked against a reference point at launch and \
                before every submission.
                """)
        }
    }
}
