import ReparaCore
import SwiftUI

@main
struct ReparaApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
    }
}

/// Everything past the welcome screen leads to filing something, and filing
/// happens under the user's own portal account. So the account is the gate: no
/// session, no capture flow.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isRestoringSession {
            LaunchView()
        } else if model.account == nil {
            WelcomeView()
        } else {
            signedInFlow(model: model)
        }
    }

    @ViewBuilder private func signedInFlow(model: AppModel) -> some View {
        @Bindable var model = model

        NavigationStack {
            Group {
                switch model.stage {
                case .capture:
                    CaptureView()
                case .drafting:
                    DraftingView()
                case .review:
                    ReviewView()
                case let .filed(result):
                    FiledView(result: result)
                case let .dryRan(payload, bytes):
                    DryRunView(payload: payload, bytes: bytes)
                }
            }
            .navigationTitle("Repara")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { ReportsView() } label: {
                        Label("Reports", systemImage: "list.bullet")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.showingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $model.showingSettings) { SettingsView() }
        }
    }
}

// MARK: - Interstitials

/// Held for one round trip to `/utilizador` while the stored cookie is checked,
/// so a returning user goes straight to Capture instead of being shown a
/// sign-up screen they do not need.
struct LaunchView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DraftingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            Text("Reading the photo…")
                .font(.headline)
            Text("\(model.providerName) picks the report type and drafts the Portuguese. You will see and can edit both before anything is filed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FiledView: View {
    let result: SubmitResult
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            VStack(spacing: 8) {
                Text("Filed").font(.title2.bold())
                Text(result.numero)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            Text("A council worker will be dispatched. There is no way to withdraw this from the app — the occurrence number above is how you follow it up.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Report something else") { model.startOver() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DryRunView: View {
    let payload: String
    let bytes: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Dry run — nothing was sent", systemImage: "checkmark.shield")
                    .font(.headline)
                    .foregroundStyle(.orange)

                Text("This is the exact `obj` part that would have been posted, alongside \(bytes.formatted(.byteCount(style: .file))) of multipart body including the photo.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(payload)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: 10))

                Button("Start over") { model.startOver() }
                    .buttonStyle(.bordered)
            }
            .padding()
        }
    }
}
