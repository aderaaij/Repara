import Foundation

public struct Credentials: Sendable, Equatable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Sign-in against the portal.
///
/// A single `JSESSIONID` cookie, established by a plain form POST to
/// `/gopiv2/login.jsp` with `provider=AD`. No CSRF token, no `Authorization`
/// header. Tomcat issues a session id on the landing page and rotates it on
/// successful auth, so the client GETs first and lets the POST overwrite it.
///
/// **`login.jsp` answers 200 with the login form again on bad credentials**
/// rather than an error status, so success is decided by a follow-up
/// `GET /utilizador`, never by the POST.
public actor Auth {
    private let client: PortalClient
    private var cachedUser: Utilizador?

    public init(client: PortalClient) {
        self.client = client
    }

    public var user: Utilizador? { cachedUser }

    /// The auth smoke test. Returns the account, or throws.
    @discardableResult
    public func whoami() async throws -> Utilizador {
        let user = try await client.json(Utilizador.self, from: "/utilizador")
        cachedUser = user
        return user
    }

    /// True when the stored cookie still works.
    public func hasValidSession() async -> Bool {
        guard client.hasSessionCookie else { return false }
        do {
            try await whoami()
            return true
        } catch let error as PortalError where error.isAuthFailure {
            return false
        } catch {
            // A network blip is not the same as a rejected session; do not
            // throw away a good cookie because the tunnel dropped.
            return client.hasSessionCookie
        }
    }

    @discardableResult
    public func logIn(_ credentials: Credentials) async throws -> Utilizador {
        // Seed a session id, then let the POST rotate it.
        _ = try? await client.request(
            Portal.appBase + "/", absolute: true, followRedirects: false)

        _ = try await client.request(
            Portal.appBase + "/login.jsp",
            method: "POST",
            body: .form([
                "username": credentials.username,
                "password": credentials.password,
                "provider": "AD",
            ]),
            headers: ["Origin": Portal.origin, "Referer": Portal.appBase + "/"],
            absolute: true,
            followRedirects: false
        )

        do {
            let user = try await whoami()
            try Keychain.set(credentials.username, for: .portalUsername)
            try Keychain.set(credentials.password, for: .portalPassword)
            return user
        } catch let error as PortalError where error.isAuthFailure {
            throw PortalError.loginFailed
        }
    }

    /// Reuse the stored cookie if it still works, otherwise sign in again with
    /// the Keychain credentials. Keeps request volume down — this is a
    /// municipal service, not a load-test target.
    @discardableResult
    public func ensureSignedIn() async throws -> Utilizador {
        if await hasValidSession(), let user = cachedUser { return user }
        guard let username = Keychain.get(.portalUsername),
            let password = Keychain.get(.portalPassword)
        else { throw PortalError.missingCredentials }
        return try await logIn(Credentials(username: username, password: password))
    }

    public func signOut() throws {
        cachedUser = nil
        client.clearCookies()
        try Keychain.remove(.portalUsername)
        try Keychain.remove(.portalPassword)
    }

    public var hasStoredCredentials: Bool {
        Keychain.get(.portalUsername) != nil && Keychain.get(.portalPassword) != nil
    }
}
