import Foundation
import ReparaCore

/// The one thing `Drafter` needs from a language model: JSON in the shape it
/// asked for.
///
/// Both calls in this app are the same narrow job — a photo and some text go
/// in, a small validated JSON object comes out. That is the whole surface, so
/// swapping Claude for GPT or Gemini is a matter of translating one request
/// shape into another rather than rearchitecting anything.
///
/// A provider is responsible for its own auth, its own request body, and for
/// mapping its own failure modes onto `ModelError` so that the rest of the app
/// never has to know which service it is talking to.
protocol ModelProvider {
    var id: ModelProviderID { get }

    /// The response text, which must be the JSON object `request.schema`
    /// describes. Structural validation is the caller's job — see
    /// `Drafter.parse` — because a schema cannot express "an id in the bundled
    /// taxonomy" or "a position in the list I sent you".
    func complete(_ request: ModelRequest) async throws -> String
}

/// A JSON Schema, as the loosely-typed dictionary every provider ends up
/// serialising anyway.
typealias JSONSchema = [String: Any]

// MARK: - The request

/// Provider-neutral. Everything here is something all three providers can
/// express; anything one of them cannot honour is documented on the field.
struct ModelRequest {
    var model: String
    var system: String
    var userText: String
    /// JPEG, already downscaled. See `PhotoScaler` — the full-resolution
    /// original goes to the council, never to a model provider.
    var image: Data?
    var schema: JSONSchema
    /// Some providers require the schema to be named. It never reaches the
    /// model's context; it only identifies the schema for caching.
    var schemaName: String
    var maxTokens: Int
    var effort: Effort

    /// Anthropic's server-side fallback: if the safety classifiers decline,
    /// the API re-runs the request on the recommended model rather than
    /// handing back a refusal. **Ignored by the other providers**, which have
    /// no equivalent — so a refusal there is a refusal.
    var allowFallbacks: Bool = false

    /// Deliberately three levels rather than each provider's full ladder. This
    /// app makes two calls and the choice between them is "the one that routes
    /// a report to a department" and "the one that compares a few sentences";
    /// a finer dial would be a setting nobody could calibrate.
    enum Effort: String {
        case low, medium, high
    }
}

// MARK: - Failures

/// Every way a model call can fail, in the app's own vocabulary rather than
/// any one provider's.
///
/// The messages name the configured provider, because "the API returned 401"
/// is unhelpful to someone who has three keys stored and has forgotten which
/// one is selected.
enum ModelError: Error, CustomStringConvertible {
    case missingAPIKey(ModelProviderID)
    case refused(ModelProviderID, category: String?, explanation: String?)
    case truncated(ModelProviderID)
    case http(ModelProviderID, status: Int, body: String)
    case malformed(ModelProviderID, String)

    /// What to show the user. As in `PortalError`, the two that are really a
    /// status code and a parser complaint keep their English `description` —
    /// they are for a bug report.
    func message(in locale: Locale) -> String {
        switch self {
        case let .missingAPIKey(provider):
            return String(
                localized: """
                    No \(provider.displayName) API key stored. Add one in Settings — it stays in \
                    the Keychain and never leaves this phone except to \(provider.host).
                    """,
                bundle: locale.bundle, locale: locale)
        case let .refused(provider, category, explanation):
            let detail = [category, explanation].compactMap { $0 }.joined(separator: ": ")
            let named =
                detail.isEmpty ? provider.displayName : "\(provider.displayName) (\(detail))"
            return String(
                localized: """
                    \(named) declined this request. Write the description yourself and pick a \
                    type — everything else still works.
                    """,
                bundle: locale.bundle, locale: locale)
        case let .truncated(provider):
            return String(
                localized:
                    "\(provider.displayName)'s reply was cut off before it finished. Try again.",
                bundle: locale.bundle, locale: locale)
        case .http, .malformed:
            return description
        }
    }

    var description: String {
        switch self {
        case let .missingAPIKey(provider):
            return """
                No \(provider.displayName) API key stored. Add one in Settings — it stays in the \
                Keychain and never leaves this phone except to \(provider.host).
                """
        case let .refused(provider, category, explanation):
            let detail = [category, explanation].compactMap { $0 }.joined(separator: ": ")
            return """
                \(provider.displayName) declined this request\(detail.isEmpty ? "" : " (\(detail))"). \
                Write the description yourself and pick a type — everything else still works.
                """
        case let .truncated(provider):
            return "\(provider.displayName)'s reply was cut off before it finished. Try again."
        case let .http(provider, status, body):
            return "The \(provider.displayName) API returned \(status). \(body.prefix(200))"
        case let .malformed(provider, detail):
            return "Could not read \(provider.displayName)'s reply: \(detail)"
        }
    }
}

// MARK: - Which provider

enum ModelProviderID: String, CaseIterable, Identifiable {
    case anthropic
    case openAI
    case gemini

    var id: String { rawValue }

    /// What the user sees. The product name rather than the company's, because
    /// that is what is printed on the key they are pasting in.
    var displayName: String {
        switch self {
        case .anthropic: return "Claude"
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        }
    }

    /// The only host this provider's key is ever sent to. Shown to the user
    /// verbatim, so it has to stay true.
    var host: String {
        switch self {
        case .anthropic: return "api.anthropic.com"
        case .openAI: return "api.openai.com"
        case .gemini: return "generativelanguage.googleapis.com"
        }
    }

    /// Keys are stored per provider, so switching back and forth does not make
    /// the user dig their key out again.
    var keychainKey: Keychain.Key {
        switch self {
        case .anthropic: return .claudeAPIKey
        case .openAI: return .openAIAPIKey
        case .gemini: return .geminiAPIKey
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openAI: return "sk-…"
        case .gemini: return "AIza…"
        }
    }

    /// Picking one of 127 types from a photograph routes the report to a
    /// council department, so the draft gets the strongest model each provider
    /// offers.
    var defaultDraftModel: String {
        switch self {
        case .anthropic: return "claude-opus-5"
        case .openAI: return "gpt-5"
        case .gemini: return "gemini-3-pro"
        }
    }

    /// Comparing a few sentences against at most eight more is narrow, and its
    /// mistakes are visible next to the reports it compared, so this tier is a
    /// step down on purpose.
    var defaultJudgeModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5"
        case .openAI: return "gpt-5-mini"
        case .gemini: return "gemini-3-flash"
        }
    }

    func makeProvider() -> any ModelProvider {
        switch self {
        case .anthropic: return AnthropicProvider()
        case .openAI: return OpenAIProvider()
        case .gemini: return GeminiProvider()
        }
    }
}

// MARK: - Settings

/// Which provider is selected and which models it should use.
///
/// Model ids are overridable free text rather than a fixed list because they
/// change faster than this app ships — a default that goes stale must be
/// something the user can fix in Settings, not a reason to wait for a release.
enum ModelSettings {

    static var provider: ModelProviderID {
        get {
            UserDefaults.standard.string(forKey: "modelProvider")
                .flatMap(ModelProviderID.init(rawValue:)) ?? .anthropic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "modelProvider") }
    }

    /// True when the *selected* provider has a key. The other providers'
    /// stored keys are irrelevant to whether drafting can happen right now.
    static var hasAPIKey: Bool {
        Keychain.get(provider.keychainKey)?.isEmpty == false
    }

    static func draftModel(for provider: ModelProviderID) -> String {
        override("draftModel", provider) ?? provider.defaultDraftModel
    }

    static func judgeModel(for provider: ModelProviderID) -> String {
        override("judgeModel", provider) ?? provider.defaultJudgeModel
    }

    static func setDraftModel(_ value: String?, for provider: ModelProviderID) {
        setOverride(value, "draftModel", provider)
    }

    static func setJudgeModel(_ value: String?, for provider: ModelProviderID) {
        setOverride(value, "judgeModel", provider)
    }

    private static func override(_ name: String, _ provider: ModelProviderID) -> String? {
        let value = UserDefaults.standard.string(forKey: "\(name).\(provider.rawValue)")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func setOverride(
        _ value: String?, _ name: String, _ provider: ModelProviderID
    ) {
        let key = "\(name).\(provider.rawValue)"
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

// MARK: - Shared transport

/// The parts of an HTTP call that are the same whichever provider answers it.
enum ModelTransport {

    /// 120 s, because a draft on a high-effort model with a photograph
    /// attached is not a fast request and the user is standing in the street.
    static let timeout: TimeInterval = 120

    static func apiKey(for provider: ModelProviderID) throws -> String {
        guard let key = Keychain.get(provider.keychainKey), !key.isEmpty else {
            throw ModelError.missingAPIKey(provider)
        }
        return key
    }

    static func send(
        _ request: URLRequest,
        provider: ModelProviderID
    ) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelError.malformed(provider, "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ModelError.http(
                provider,
                status: http.statusCode,
                body: String(data: data.prefix(2000), encoding: .utf8) ?? ""
            )
        }
        return data
    }

    static func json(_ data: Data, provider: ModelProviderID) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelError.malformed(provider, "response was not a JSON object")
        }
        return root
    }
}
