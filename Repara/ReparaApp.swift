import ReparaCore
import SwiftUI
import UIKit

@main
struct ReparaApp: App {
    #if DEBUG
        @State private var model =
            ScreenshotMode.isActive ? AppModel(session: ScreenshotMode.session) : AppModel()
    #else
        @State private var model = AppModel()
    #endif

    init() {
        #if DEBUG
            // Before any view is built — `SettingsView` reads the selected
            // provider into `@State` the moment it is constructed. No-op unless
            // `--screenshot-scene` was passed.
            ScreenshotMode.applyDefaults()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            // Everything the user reads sits inside this, so the language
            // setting reaches every screen from one place rather than being
            // remembered at each one.
            LocalizedRoot {
                #if DEBUG
                    if IconExport.isActive {
                        // Draws the app icon from the same view the launch screen
                        // shows. See `Tools/appicon.sh`.
                        IconExportHost()
                    } else if ScreenshotMode.isActive {
                        // A stubbed portal and one screen per launch. See
                        // `ScreenshotMode` — it cannot submit, and it is compiled out
                        // of release builds entirely.
                        ScreenshotHost()
                            .environment(model)
                    } else {
                        RootView()
                            .environment(model)
                            .task { await model.start() }
                    }
                #else
                    RootView()
                        .environment(model)
                        .task { await model.start() }
                #endif
            }
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
            // The stage is the screen, so the title says which one rather than
            // repeating the app's name at somebody who just opened it.
            .navigationTitle(title(for: model.stage))
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
        .tint(Repara.ink)
    }

    /// `LocalizedStringKey` rather than `String`: the `String` overload of
    /// `navigationTitle` is the verbatim one, so returning it here would print
    /// these five words in English in a Portuguese app and look like a
    /// translation that had been missed rather than one that never ran.
    private func title(for stage: AppModel.Stage) -> LocalizedStringKey {
        switch stage {
        case .capture: "Report"
        case .drafting: "Drafting"
        case .review: "Review"
        case .filed: "Filed"
        case .dryRan: "Dry run"
        }
    }
}

// MARK: - Interstitials

/// Held for one round trip to `/utilizador` while the stored cookie is checked,
/// so a returning user goes straight to Capture instead of being shown a
/// sign-up screen they do not need.
struct LaunchView: View {
    var body: some View {
        ZStack {
            Repara.canvas.ignoresSafeArea()
            VStack(spacing: 22) {
                ReparaMark(size: 104)
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                ProgressView().tint(Repara.ink)
            }
        }
    }
}

/// The one wait in the flow that is worth explaining while it happens: it is
/// spending a model call, and what comes back decides which council department
/// gets the report.
struct DraftingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Repara.canvas.ignoresSafeArea()
            VStack(spacing: 22) {
                AmberSpinner()
                Text("Reading the photo…")
                    .font(.title3.weight(.semibold))
                Text(
                    """
                    \(model.providerName) picks one of 127 report types and drafts the Portuguese. \
                    You read and can edit both before anything is filed.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 44)
            }
        }
    }
}

/// Amber, because waiting is attention rather than action, and the only place in
/// the app where the accent moves.
private struct AmberSpinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(Repara.amber, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .background {
                Circle().strokeBorder(Repara.ink.opacity(0.14), lineWidth: 3)
            }
            .frame(width: 56, height: 56)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

/// The one screen in the app that reports something irreversible having
/// happened. It says so plainly, and it hands over the occurrence number,
/// because that number is the only way to follow the report up.
struct FiledView: View {
    let result: SubmitResult
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemBackground), Repara.canvas],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Repara.done, in: .rect(cornerRadius: 28, style: .continuous))
                        .shadow(color: Repara.done.opacity(0.32), radius: 14, y: 6)

                    Text("Filed with the council")
                        .font(.system(size: 28, weight: .bold))
                        .padding(.top, 16)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(
                        """
                        A worker will be dispatched. This cannot be withdrawn from the app — the \
                        number below is how you follow it up.
                        """
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Occurrence")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(result.numero)
                                .font(.system(size: 19, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            UIPasteboard.general.string = result.numero
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 17))
                                .foregroundStyle(Repara.ink)
                                .frame(width: 44, height: 44)
                                .background(.quaternary, in: .circle)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        .quaternary, in: .rect(cornerRadius: 18, style: .continuous))
                    .padding(.top, 18)
                }
                .padding(22)
                .glassEffect(
                    .regular, in: .rect(cornerRadius: Repara.Radius.bar, style: .continuous))

                Button("Report something else") { model.startOver() }
                    .buttonStyle(InkButtonStyle(height: 60))
                    .padding(.top, 6)

                // The moment somebody most wants this list is the moment they
                // have just added to it.
                NavigationLink {
                    ReportsView()
                } label: {
                    Text("See my reports")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Repara.ink)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
        }
    }
}

/// What would have been posted, and the fact that it was not.
///
/// Green here is honest — nothing was sent is a completed, verified state, not
/// an absence of information. That is the distinction `CautionTier.unverified`
/// exists to protect, and this is the other side of it.
struct DryRunView: View {
    let payload: String
    let bytes: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("Nothing was sent").font(.headline)
                    } icon: {
                        Image(systemName: "checkmark.shield.fill")
                    }
                    .foregroundStyle(Repara.done)

                    Text(
                        """
                        This is the exact `obj` part that would have been posted, alongside \
                        \(bytes.formatted(.byteCount(style: .file))) of multipart body \
                        including the photo.
                        """
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Repara.card, in: .rect(cornerRadius: Repara.Radius.card, style: .continuous))

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(payload)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color(.systemGray5))
                        .textSelection(.enabled)
                        .padding(14)
                }
                .background(
                    Color(red: 0.110, green: 0.110, blue: 0.118),
                    in: .rect(cornerRadius: Repara.Radius.card, style: .continuous))

                HStack(spacing: 10) {
                    Button("Back to review") { model.stage = .review }
                        .buttonStyle(GlassButtonStyle())
                    Button("Start over") { model.startOver() }
                        .font(.system(size: 17))
                        .foregroundStyle(Repara.ink)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(.quaternary, in: .capsule)
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
        .background(Repara.canvas)
    }
}
