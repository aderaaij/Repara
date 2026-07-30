import Foundation
import Testing

@testable import ReparaCore

/// The app API's token is a second, independent session — the web cookie does
/// not satisfy it. These tests pin the parts of acquiring it that were
/// established by watching the server reject the alternatives, and would be
/// silently reintroduced by anyone "tidying" the login body.
@Suite("App session")
struct AppSessionTests {

    private static let account = Credentials(username: "a@example.invalid", password: "pw")

    private static func body(_ token: String) -> Data {
        Data(#"{"data":{"authToken":"\#(token)"},"gap":{"operationSucceeded":true}}"#.utf8)
    }

    private static let rejected = Data(
        #"""
        {"gap":{"errorMessage":"Sessão não encontrada","invalidSession":true,
                "invalidVersion":false,"nextScreen":0,"operationSucceeded":false}}
        """#.utf8)

    // MARK: The login body

    /// `provider` is required and its value here is `EXT` — the web
    /// `login.jsp` takes `AD` for the very same credentials. Omitting it fails
    /// with "provider não encontrado", which says nothing about the password
    /// and sends you looking in the wrong place.
    @Test("the login sends provider EXT, not the web API's AD")
    func loginSendsExtProvider() async throws {
        let (session, mock) = MockURLProtocol.make { _ in
            .init(body: Self.body("tok"))
        }
        let app = AppSession(client: PortalClient(session: session)) { Self.account }

        #expect(try await app.token() == "tok")

        let sent = try #require(mock.requests.first)
        let json = try #require(sent.httpBodyText)
        #expect(json.contains("\"provider\":\"EXT\""))
        #expect(!json.contains("\"provider\":\"AD\""))
    }

    /// `device` is written to the database on a *successful* login, so these
    /// widths only bite once the password is right — which is exactly when a
    /// user hits them. `jailbroken` is `varchar(1)`: sending `"false"` fails
    /// with "value too long for type character varying(1)".
    @Test("the device block respects the database column widths")
    func deviceRespectsColumnWidths() async throws {
        let (session, mock) = MockURLProtocol.make { _ in .init(body: Self.body("tok")) }
        let app = AppSession(client: PortalClient(session: session)) { Self.account }
        _ = try await app.token()

        let sentRequest = try #require(mock.requests.first)
        let json = try #require(sentRequest.httpBodyText)
        struct Sent: Decodable {
            struct Device: Decodable {
                let name: String
                let model: String
                let jailbroken: String
            }
            let device: Device
        }
        let sent = try JSONDecoder().decode(Sent.self, from: Data(json.utf8))

        #expect(sent.device.jailbroken.count == 1, "jailbroken is varchar(1)")
        #expect(sent.device.jailbroken == "0" || sent.device.jailbroken == "1")
        #expect(sent.device.model.count <= 32)
        #expect(sent.device.name.count <= 20)
    }

    /// The token lives under `data`, like every other app-API payload.
    @Test("a login that answers without a token is a failure, not an empty token")
    func missingTokenIsFailure() async throws {
        let (session, _) = MockURLProtocol.make { _ in .init(body: Self.rejected) }
        let app = AppSession(client: PortalClient(session: session)) { Self.account }

        await #expect(throws: PortalError.self) { try await app.token() }
    }

    // MARK: Laziness

    /// The token must not be fetched until something needs it. Sign-in is
    /// `Auth`'s business alone — the map API being down may not stop somebody
    /// filing a report.
    @Test("no request is made until a token is actually wanted")
    func acquisitionIsLazy() async throws {
        let (session, mock) = MockURLProtocol.make { _ in .init(body: Self.body("tok")) }
        let app = AppSession(client: PortalClient(session: session)) { Self.account }

        #expect(await app.hasToken == false)
        #expect(mock.requests.isEmpty, "constructing a session must cost nothing")

        _ = try await app.token()
        #expect(await app.hasToken)
        #expect(mock.requests.count == 1)
    }

    @Test("the token is fetched once and reused")
    func tokenIsCached() async throws {
        let (session, mock) = MockURLProtocol.make { _ in .init(body: Self.body("tok")) }
        let app = AppSession(client: PortalClient(session: session)) { Self.account }

        for _ in 0..<3 { _ = try await app.token() }
        #expect(mock.requests.count == 1, "a cached token must not be re-bought")
    }

    @Test("with no stored account it asks for credentials rather than guessing")
    func noCredentials() async throws {
        let (session, mock) = MockURLProtocol.make { _ in .init(body: Self.body("tok")) }
        let app = AppSession(client: PortalClient(session: session)) { nil }

        await #expect(throws: PortalError.self) { try await app.token() }
        #expect(mock.requests.isEmpty, "must not call the portal with no account")
    }

    // MARK: Expiry

    /// An expired token arrives as HTTP 200 with `invalidSession`. One retry
    /// covers a token that aged out between screens; more would be a loop
    /// against a municipal server.
    @Test("an expired token is re-acquired exactly once")
    func expiredTokenRetriesOnce() async throws {
        let calls = Counter()
        let (session, _) = MockURLProtocol.make { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/login") { return .init(body: Self.body("fresh")) }
            // The first area search rejects, the second succeeds.
            return calls.next() == 0
                ? .init(body: Self.rejected)
                : .init(body: Data(#"{"data":{"ocos":[]},"gap":{"operationSucceeded":true}}"#.utf8))
        }
        let client = PortalClient(session: session)
        let app = AppSession(client: client) { Self.account }
        _ = try await app.token()

        var attempts = 0
        let result = try await app.withToken { _ -> String in
            attempts += 1
            if attempts == 1 { throw PortalError.notAuthenticated(status: 200, path: "x") }
            return "ok"
        }

        #expect(result == "ok")
        #expect(attempts == 2, "exactly one retry")
    }

    /// A token that is rejected twice is a real rejection. It must surface, not
    /// spin.
    @Test("a token rejected twice gives up")
    func repeatedRejectionGivesUp() async throws {
        let (session, _) = MockURLProtocol.make { _ in .init(body: Self.body("tok")) }
        let app = AppSession(client: PortalClient(session: session)) { Self.account }

        var attempts = 0
        await #expect(throws: PortalError.self) {
            try await app.withToken { _ -> String in
                attempts += 1
                throw PortalError.notAuthenticated(status: 200, path: "x")
            }
        }
        #expect(attempts == 2, "two tries, then stop")
    }

    /// Invalidating must actually force a new fetch, or the retry is a no-op
    /// that replays the dead token.
    @Test("invalidate forces a fresh token")
    func invalidateRefetches() async throws {
        let (session, mock) = MockURLProtocol.make { _ in .init(body: Self.body("tok")) }
        let app = AppSession(client: PortalClient(session: session)) { Self.account }

        _ = try await app.token()
        await app.invalidate()
        #expect(await app.hasToken == false)
        _ = try await app.token()

        #expect(mock.requests.count == 2)
    }
}

/// A tiny thread-safe counter — the stub handler is `@Sendable` and runs off
/// the test's own task.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

extension URLRequest {
    /// `URLProtocol` moves a body to `httpBodyStream`, so `httpBody` is nil by
    /// the time a stub sees it.
    var httpBodyText: String? {
        if let body = httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
