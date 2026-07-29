import Foundation
import Testing

@testable import ReparaCore

/// A `URLSession` that answers from a fixture instead of the network.
///
/// Every test in this target runs with no credentials and no connection — a
/// municipal service is not a fixture server, and the portal must never be
/// touched by CI. Requests go through the real decoding path, so these tests
/// exercise `Morada`'s two shapes and the `nearBy` stripping for real rather
/// than against hand-built Swift values.
///
/// Stubs are keyed to a token carried in a request header rather than held in
/// one global, because Swift Testing runs tests in parallel and a shared stub
/// gets clobbered mid-test by whichever suite is running alongside.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    struct Stub: Sendable {
        var status: Int = 200
        var contentType: String = "application/json"
        var body: Data
    }

    /// One test's mock: its canned answer and what it was asked for.
    final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private let handler: @Sendable (URLRequest) -> Stub
        private var recorded: [URLRequest] = []

        init(handler: @escaping @Sendable (URLRequest) -> Stub) {
            self.handler = handler
        }

        var requests: [URLRequest] { lock.withLock { recorded } }

        fileprivate func answer(_ request: URLRequest) -> Stub {
            lock.withLock { recorded.append(request) }
            return handler(request)
        }
    }

    static let tokenHeader = "X-Repara-Test-Stub"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessions: [String: Session] = [:]

    /// A `URLSession` wired to this protocol, plus the handle to inspect what it
    /// was asked for. Cookies are off, so tests never touch the shared store.
    static func make(_ handler: @escaping @Sendable (URLRequest) -> Stub)
        -> (session: URLSession, mock: Session)
    {
        let token = UUID().uuidString
        let mock = Session(handler: handler)
        lock.withLock { sessions[token] = mock }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.httpAdditionalHeaders = PortalClient.browserHeaders.merging([tokenHeader: token]) {
            _, new in new
        }
        return (URLSession(configuration: config), mock)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let token = request.value(forHTTPHeaderField: Self.tokenHeader),
            let mock = Self.lock.withLock({ Self.sessions[token] }),
            let url = request.url
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stub = mock.answer(request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": stub.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Fixtures

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json"),
            "fixture \(name).json is missing from the test bundle"
        )
        return try Data(contentsOf: url)
    }

    static func json(_ name: String) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: try data(name)) as? [String: Any],
            "fixture \(name).json is not a JSON object"
        )
    }

    /// A client that answers every request with the named fixture, plus the
    /// mock handle so a test can assert on what was actually requested.
    static func client(returning name: String) throws -> (PortalClient, MockURLProtocol.Session) {
        let body = try data(name)
        let (session, mock) = MockURLProtocol.make { _ in .init(body: body) }
        return (PortalClient(session: session), mock)
    }

    /// A client that answers each `ocoTipo` with its own fixture — the way the
    /// live server behaves, since it scopes `nearBy` to the type asked for.
    ///
    /// A type with no entry gets `status`, which is how a cluster search's
    /// partial-failure path is exercised: one type falls over, the rest answer.
    static func client(
        perType fixtures: [Int: String],
        otherwise status: Int = 500
    ) throws -> (PortalClient, MockURLProtocol.Session) {
        let bodies = try fixtures.mapValues { try data($0) }
        let (session, mock) = MockURLProtocol.make { request in
            let tipo =
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "ocoTipo" }?.value
                .flatMap(Int.init)
            guard let tipo, let body = bodies[tipo] else {
                return .init(status: status, body: Data("{}".utf8))
            }
            return .init(body: body)
        }
        return (PortalClient(session: session), mock)
    }
}

extension MockURLProtocol.Session {
    /// The `ocoTipo` of every request made, in order — the cost this test just
    /// put on a municipal server.
    var requestedTypes: [Int] {
        requests.compactMap { request in
            request.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "ocoTipo" }?.value
            }.flatMap(Int.init)
        }
    }
}

extension TipoOcorrencia {
    /// The type the verified capture used.
    static let litter = TipoOcorrencia(
        id: 262,
        areaOcorrenciaId: 10,
        area: "Higiene Urbana",
        descricao: "Sacos ou outros lixos abandonados",
        slug: "sacos-ou-outros-lixos-abandonados",
        en: "Abandoned bin bags or other litter",
        areaEn: "Urban Hygiene"
    )
}
