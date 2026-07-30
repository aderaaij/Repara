import Foundation

/// The second session.
///
/// The portal's app API does not accept the web `JSESSIONID` — a fresh, valid
/// cookie sent with no token is answered `invalidSession`, tested rather than
/// assumed. So a signed-in account holds two independent sessions against the
/// same server: `Auth`'s cookie, which `Geo` and `Submit` need, and this token.
///
/// **It is acquired lazily and never gates sign-in.** `Auth` alone decides
/// whether somebody is signed in, because the account gates every screen that
/// leads to filing something, and the map is not one of those screens. Making
/// sign-in depend on two logins would mean an outage in the *map* API locking
/// somebody out of *reporting a pothole* — the same reasoning that keeps
/// `outstandingChecks` off the submit gate. Whoever is standing in the street
/// files their report; the map can fail on its own.
///
/// The token is deliberately **not** persisted. It is derived from credentials
/// already in the Keychain, so re-acquiring it costs one request and cannot go
/// stale on disk; a stored token would need its own expiry reasoning and would
/// be a second secret to invalidate at sign-out.
public actor AppSession {
    private let client: PortalClient
    private let credentials: @Sendable () -> Credentials?
    private var cached: String?

    /// - Parameter credentials: where to get the account from. Defaults to the
    ///   Keychain, which is the only thing the app itself should pass; the
    ///   parameter exists so tests never touch the real one.
    public init(
        client: PortalClient,
        credentials: (@Sendable () -> Credentials?)? = nil
    ) {
        self.client = client
        self.credentials = credentials ?? {
            guard let username = Keychain.get(.portalUsername),
                let password = Keychain.get(.portalPassword)
            else { return nil }
            return Credentials(username: username, password: password)
        }
    }

    /// True once a token has been fetched. Does not mean it still works — only
    /// a request can establish that.
    public var hasToken: Bool { cached != nil }

    /// The token, fetched on first use.
    public func token() async throws -> String {
        if let cached { return cached }
        guard let account = credentials() else { throw PortalError.missingCredentials }

        let token = try await logIn(account)
        cached = token
        return token
    }

    /// Drop the token so the next call fetches a fresh one. Called when the
    /// server says `invalidSession`.
    public func invalidate() {
        cached = nil
    }

    /// Run something with a token, re-acquiring once if the server rejects it.
    ///
    /// The app API reports an expired token as HTTP 200 with
    /// `invalidSession: true`, which `AreaSearch` turns into
    /// `.notAuthenticated`. Retrying once covers the ordinary case of a token
    /// that aged out between screens without looping on a genuine rejection.
    public func withToken<T>(_ body: (String) async throws -> T) async throws -> T {
        do {
            return try await body(try await token())
        } catch let error as PortalError where error.isAuthFailure {
            invalidate()
            return try await body(try await token())
        }
    }

    // MARK: Sign-in

    /// `POST /gopiv2/publico-app/utilizador/login`.
    ///
    /// Two things here are not guessable and were both established by watching
    /// the server reject the alternatives:
    ///
    /// - **`provider` is required**, and the app API's value for an
    ///   email-and-password login is `EXT` — *not* the `AD` that the web
    ///   `login.jsp` takes for the same credentials. Omitting it fails with
    ///   "provider não encontrado" rather than anything about credentials.
    /// - **`device` is written to the database on success**, so its column
    ///   widths only bite once the password is right. `jailbroken` is
    ///   `varchar(1)`: `"0"` or `"1"`, never `"false"`. `model` is capped at 32
    ///   characters and `name` at 20, matching what the Android client
    ///   truncates to.
    private func logIn(_ credentials: Credentials) async throws -> String {
        struct Request: Encodable {
            let username: String
            let password: String
            let provider = "EXT"
            let device = Device()

            struct Device: Encodable {
                let name = "Repara"
                let model = "iPhone"
                let os = "iOS"
                let osVersion = "17.0"
                /// `varchar(1)`. Not a boolean, and not the word.
                let jailbroken = "0"
            }
        }
        struct Response: Decodable {
            let data: Payload?
            let gap: GapEnvelope?
            struct Payload: Decodable { let authToken: String? }
        }

        let body = try JSONEncoder().encode(
            Request(username: credentials.username, password: credentials.password))

        let response = try await client.json(
            Response.self,
            from: AppPortal.publicBase + "/utilizador/login",
            method: "POST",
            body: .raw(body, contentType: "application/json"),
            headers: AppPortal.gapHeader(),
            absolute: true
        )

        guard let token = response.data?.authToken, !token.isEmpty else {
            // `errorMessage` is unsanitised — a failed login has been seen to
            // answer with raw Postgres text. It belongs in a log, not on a
            // screen, so the thrown error is the app's own wording.
            throw PortalError.loginFailed
        }
        return token
    }
}
