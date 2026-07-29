import Foundation

// MARK: - Errors

public enum PortalError: Error, CustomStringConvertible, Sendable {
    /// 401/403 — the session cookie is missing or expired. Log in again.
    case notAuthenticated(status: Int, path: String)
    case http(status: Int, path: String, body: String)
    case notJSON(path: String, contentType: String, body: String)
    /// The API shape changed in a way that makes it unsafe to build a report.
    case unexpectedShape(String, path: String)
    case noAddressFound(at: LatLng, point: PtTm06, insideLisbon: Bool)
    case loginFailed
    case missingCredentials

    public var description: String {
        switch self {
        case let .notAuthenticated(status, path):
            return "Not authenticated (\(status)) for \(path). Sign in again."
        case let .http(status, path, body):
            return "\(path) failed with \(status). \(body.prefix(300))"
        case let .notJSON(path, contentType, _):
            return """
                Expected JSON from \(path) but got \(contentType). \
                The portal's API shape may have changed.
                """
        case let .unexpectedShape(message, path):
            return "\(message) (\(path))"
        case let .noAddressFound(at, point, insideLisbon):
            let where_ = "\(at.lat), \(at.lng) (EPSG:3763 \(Int(point.x)), \(Int(point.y)))"
            return insideLisbon
                ? """
                No address at \(where_). The point is inside Lisbon but matched neither a \
                building nor a street. Drag the pin a few metres — onto the building \
                frontage, or onto the roadway.
                """
                : """
                No address at \(where_). The point is outside the Lisbon municipality, \
                which Na Minha Rua LX does not cover.
                """
        case .loginFailed:
            return """
                Sign-in failed — the portal did not establish a session. Check the email \
                and password. Note that Google and Apple sign-in will not work here; this \
                app implements only the native account login.
                """
        case .missingCredentials:
            return "No portal credentials stored. Sign in from Settings."
        }
    }

    public var isAuthFailure: Bool {
        if case .notAuthenticated = self { return true }
        return false
    }
}

// MARK: - Endpoints

public enum Portal {
    public static let origin = "https://naminharualx.cm-lisboa.pt"
    public static let appBase = origin + "/gopiv2"
    public static let apiBase = appBase + "/naminharuav2"

    /// The portal's own account pages, opened in Safari rather than reproduced
    /// natively.
    ///
    /// There is no registration endpoint in the captured session, and creating
    /// an account means consenting to the council's Política de Privacidade and
    /// Proteção de Dados. A form in this app would be asking the user to accept
    /// terms it never showed them, on behalf of a data controller it does not
    /// speak for — and the flow ends in an email confirmation we cannot
    /// complete anyway. Handing off to the real page also means the user types
    /// a new password into cm-lisboa.pt with the domain visible, not into an
    /// unofficial client.
    ///
    /// `login.jsp` links to both: "Crie um novo utilizador" and "Recuperar
    /// password", the latter a client-side route on the same page.
    public static let registration = appBase + "/registo.html"
    public static let passwordRecovery = appBase + "/registo.html#/pass_recover/"

    /// Paths are concatenated rather than built with `URL(fileURLWithPath:)`
    /// because trailing slashes are load-bearing here: `/ocorrencias/my` 404s
    /// with one, `/ocorrencias/getGeoAttributes/` needs one.
    static func url(_ path: String, query: [String: String] = [:], absolute: Bool = false) -> URL? {
        guard var components = URLComponents(string: absolute ? path : apiBase + path) else {
            return nil
        }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }
}

// MARK: - Client

public enum RequestBody: Sendable {
    case form([String: String])
    case raw(Data, contentType: String?)
}

/// One HTTP call against the portal, with the session cookie applied.
///
/// The portal is an AngularJS app; requests that do not look like they came
/// from it are likelier to trip a filter, so the browser's headers are
/// mirrored. `URLSession` carries `JSESSIONID` automatically via
/// `HTTPCookieStorage`, which also persists it across launches — a cookie was
/// still accepted 109 minutes after login, so sessions are not short-lived.
public final class PortalClient: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.httpCookieAcceptPolicy = .always
            config.httpShouldSetCookies = true
            config.httpAdditionalHeaders = Self.browserHeaders
            config.timeoutIntervalForRequest = 30
            config.waitsForConnectivity = true
            self.session = URLSession(configuration: config)
        }
    }

    static let browserHeaders: [String: String] = [
        "Accept": "application/json, text/plain, */*",
        "Accept-Language": "pt-PT,pt;q=0.9,en;q=0.8",
        "Referer": appBaseReferer,
        "User-Agent":
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36",
    ]
    private static let appBaseReferer = Portal.appBase + "/naminharua/index.jsp"

    // MARK: Requests

    @discardableResult
    public func request(
        _ path: String,
        method: String = "GET",
        query: [String: String] = [:],
        body: RequestBody? = nil,
        headers: [String: String] = [:],
        absolute: Bool = false,
        followRedirects: Bool = true
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        guard let url = Portal.url(path, query: query, absolute: absolute) else {
            throw PortalError.unexpectedShape("Could not build a URL", path: path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        switch body {
        case let .form(fields):
            var components = URLComponents()
            components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = (components.percentEncodedQuery ?? "").data(using: .utf8)
            request.setValue(
                "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        case let .raw(data, contentType):
            request.httpBody = data
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        case nil:
            break
        }

        let (data, response) = try await session.data(
            for: request,
            delegate: followRedirects ? nil : RedirectBlocker()
        )
        guard let http = response as? HTTPURLResponse else {
            throw PortalError.unexpectedShape("Non-HTTP response", path: path)
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw PortalError.notAuthenticated(status: http.statusCode, path: path)
        }
        let isRedirect = (300..<400).contains(http.statusCode)
        if !(200..<300).contains(http.statusCode) && !(isRedirect && !followRedirects) {
            throw PortalError.http(
                status: http.statusCode,
                path: path,
                body: String(data: data.prefix(2000), encoding: .utf8) ?? ""
            )
        }
        return (data, http)
    }

    public func json<T: Decodable>(
        _ type: T.Type,
        from path: String,
        method: String = "GET",
        query: [String: String] = [:],
        body: RequestBody? = nil,
        headers: [String: String] = [:]
    ) async throws -> T {
        let (data, response) = try await request(
            path, method: method, query: query, body: body, headers: headers)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PortalError.notJSON(
                path: path,
                contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "no content-type",
                body: String(data: data.prefix(500), encoding: .utf8) ?? ""
            )
        }
    }

    // MARK: Cookies

    /// Drop the portal's session cookie. Used by sign-out, and after a password
    /// change, so a stale `JSESSIONID` cannot outlive the credentials.
    public func clearCookies() {
        guard let storage = session.configuration.httpCookieStorage,
            let url = URL(string: Portal.origin),
            let cookies = storage.cookies(for: url)
        else { return }
        for cookie in cookies { storage.deleteCookie(cookie) }
    }

    public var hasSessionCookie: Bool {
        guard let storage = session.configuration.httpCookieStorage,
            let url = URL(string: Portal.origin)
        else { return false }
        return storage.cookies(for: url)?.contains { $0.name == "JSESSIONID" } ?? false
    }
}

/// Stops `URLSession` following the post-login redirect. The portal answers the
/// login POST with a 302 to a full HTML page; all we want from it is the cookie.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
