import ReparaCore
import SwiftUI

/// The sign-up gate, shown whenever there is no session.
///
/// Repara has no account of its own: it files under the user's Na Minha Rua LX
/// account so the council knows who reported the problem and can come back to
/// them about it. There is nothing useful to show before that exists, so this
/// screen replaces the whole flow rather than warning from inside it.
///
/// Creating the account happens on the council's own site, not here — see
/// `Portal.registration` for why.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var showingSignIn = false
    @State private var showingCatalogue = false

    var body: some View {
        // Centred when it fits, scrollable when it does not — the copy here is
        // load-bearing, and at the largest accessibility text sizes it is
        // taller than the screen.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 28) {
                    masthead
                    accountCard
                    if let error = model.error { errorNote(error) }
                    footnote
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 44)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(Repara.canvas)
        .tint(Repara.ink)
        .sheet(isPresented: $showingSignIn) { SignInView() }
        .sheet(isPresented: $showingCatalogue) { catalogue }
    }

    /// Readable without an account, deliberately: "what can I even report?" is
    /// a fair question to ask before signing up for anything, and the gate
    /// would otherwise make it unanswerable.
    private var catalogue: some View {
        NavigationStack {
            TypeCatalogueView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingCatalogue = false }
                    }
                }
        }
    }

    // MARK: Pieces

    /// The lockup, not a symbol and a title.
    ///
    /// "Unofficial client · Na Minha Rua LX" is part of the mark rather than a
    /// disclaimer in Settings, because this is the first screen anybody sees and
    /// the one place it matters that the app is visibly third-party. Nothing
    /// here borrows the council's identity — that is a black-and-white crest and
    /// municipal green.
    private var masthead: some View {
        VStack(spacing: 18) {
            ReparaMark(size: 96)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 7)
            ReparaLockup()
            Text("Report a problem in Lisbon's streets to the council, with the pin exactly where the problem is.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
    }

    private var accountCard: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                Text("You need a Na Minha Rua LX account")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text("Repara has no account of its own — it files under yours, so the council knows who reported the problem and can reach you about it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(
                Repara.card, in: .rect(cornerRadius: Repara.Radius.card, style: .continuous))

            Button("Create an account") { open(Portal.registration) }
                .buttonStyle(InkButtonStyle(height: 56))
                .padding(.top, 2)

            Button("I already have one") { showingSignIn = true }
                .buttonStyle(GlassButtonStyle(height: 52))

            Button("See what you can report") { showingCatalogue = true }
                .font(.footnote)
                .foregroundStyle(Repara.ink)
                .padding(.top, 4)
        }
    }

    private func errorNote(_ error: String) -> some View {
        Text(error)
            .font(.footnote)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footnote: some View {
        Text("Creating an account opens the council's own site in Safari. Repara does not host that form: signing up means agreeing to the council's privacy and data-protection terms, which is between you and them.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func open(_ link: String) {
        guard let url = URL(string: link) else { return }
        openURL(url)
    }
}

// MARK: - Sign in

/// Presented from the welcome screen rather than living in Settings, which is
/// unreachable until there is a session to put in it.
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var username = Keychain.get(.portalUsername) ?? ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $username)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    Button("Sign in", action: signIn)
                        .disabled(
                            username.isEmpty || password.isEmpty || model.busyMessage != nil)
                } header: {
                    Text("Na Minha Rua LX")
                } footer: {
                    Text("Only the native email and password login works; Google and Apple sign-in are not implemented. Credentials go in the Keychain.")
                }

                Section {
                    Button {
                        open(Portal.passwordRecovery)
                    } label: {
                        Label("Forgotten password", systemImage: "key")
                    }
                    Button {
                        open(Portal.registration)
                    } label: {
                        Label("Create an account", systemImage: "person.badge.plus")
                    }
                } footer: {
                    Text("Both open the council's own site in Safari, so a password is only ever typed into cm-lisboa.pt.")
                }

                if let error = model.error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func signIn() {
        Task {
            await model.signIn(username: username, password: password)
            password = ""
            // On success `RootView` swaps the welcome screen for the capture
            // flow underneath; dismissing keeps the sheet from riding along.
            if model.account != nil { dismiss() }
        }
    }

    private func open(_ link: String) {
        guard let url = URL(string: link) else { return }
        openURL(url)
    }
}
