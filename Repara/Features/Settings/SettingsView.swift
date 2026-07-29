import ReparaCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""
    @State private var savedKey = Keychain.get(.claudeAPIKey)?.isEmpty == false

    var body: some View {
        NavigationStack {
            Form {
                portalSection
                claudeSection
                submitModeSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
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

    // MARK: Claude

    @ViewBuilder private var claudeSection: some View {
        Section {
            if savedKey {
                LabeledContent("API key", value: "Stored in Keychain")
                Button("Remove key", role: .destructive) {
                    try? Keychain.set(nil, for: .claudeAPIKey)
                    savedKey = false
                }
            } else {
                SecureField("sk-ant-…", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save key") {
                    try? Keychain.set(apiKey, for: .claudeAPIKey)
                    savedKey = Keychain.get(.claudeAPIKey)?.isEmpty == false
                    apiKey = ""
                }
                .disabled(apiKey.isEmpty)
            }
        } header: {
            Text("Claude")
        } footer: {
            Text("The key cannot be shipped inside the app — anyone could extract it from the bundle. Enter it once and it stays in the Keychain, which also keeps this app free of any server of its own.")
        }
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
