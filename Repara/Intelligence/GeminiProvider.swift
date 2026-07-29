import Foundation

/// `generateContent`, over `URLSession`.
///
/// The odd one out of the three: its structured-output schema is an OpenAPI
/// subset rather than JSON Schema, and it has no equivalent of Anthropic's
/// server-side fallback. See `sanitized(_:)` for what that costs us.
struct GeminiProvider: ModelProvider {

    let id = ModelProviderID.gemini

    private static let base = "https://generativelanguage.googleapis.com/v1beta/models"

    /// Blocked before the model ever answered, or stopped partway for a
    /// content reason. Either way there is nothing to parse and the user
    /// should be told it was declined rather than shown a parse failure.
    private static let refusalReasons: Set<String> = [
        "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION", "IMAGE_SAFETY",
    ]

    func complete(_ request: ModelRequest) async throws -> String {
        let apiKey = try ModelTransport.apiKey(for: id)

        var parts: [[String: Any]] = []
        if let image = request.image {
            parts.append([
                "inline_data": [
                    "mime_type": "image/jpeg",
                    "data": image.base64EncodedString(),
                ]
            ])
        }
        parts.append(["text": request.userText])

        // No thinking configuration. Gemini's budget is expressed in tokens
        // per model rather than as a level, so mapping our three-step effort
        // onto it would be a guess that goes stale with every model — its own
        // dynamic default is the honest choice.
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": request.system]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "maxOutputTokens": request.maxTokens,
                "responseMimeType": "application/json",
                "responseSchema": Self.sanitized(request.schema),
            ],
        ]

        guard
            let url = URL(
                string:
                    "\(Self.base)/\(request.model)"
                    + ":generateContent")
        else {
            throw ModelError.malformed(id, "model id \"\(request.model)\" is not a valid URL path")
        }

        var http = URLRequest(url: url)
        http.httpMethod = "POST"
        http.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        http.setValue("application/json", forHTTPHeaderField: "content-type")
        http.timeoutInterval = ModelTransport.timeout
        http.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try text(from: try await ModelTransport.send(http, provider: id))
    }

    // MARK: Schema

    /// `responseSchema` is an OpenAPI 3.0 subset, not JSON Schema: it rejects
    /// `additionalProperties` outright, and only honours `enum` on strings.
    ///
    /// Dropping the `tipo_id` enum means Gemini is not *structurally*
    /// prevented from inventing an occurrence type the way the other two are.
    /// That is survivable and only because of two things that must stay true:
    /// the full type list is in the prompt, and `Drafter.parse` resolves the
    /// id against the bundled taxonomy and throws rather than trusting it. The
    /// same goes for `duplicate_of`, which is filtered against the list that
    /// was actually sent. Do not remove either check on the grounds that the
    /// schema covers it — on this provider it does not.
    private static func sanitized(_ schema: JSONSchema) -> JSONSchema {
        var out: JSONSchema = [:]
        let type = schema["type"] as? String

        for (key, value) in schema {
            switch key {
            case "additionalProperties":
                continue
            case "enum":
                // String enums survive; integer enums do not.
                if type == "string" { out[key] = value }
            case "properties":
                guard let properties = value as? [String: JSONSchema] else { continue }
                out[key] = properties.mapValues(sanitized)
            case "items":
                guard let items = value as? JSONSchema else { continue }
                out[key] = sanitized(items)
            default:
                out[key] = value
            }
        }
        return out
    }

    // MARK: Response

    private func text(from data: Data) throws -> String {
        let root = try ModelTransport.json(data, provider: id)

        // A prompt-level block has no candidate at all, so this has to be read
        // before reaching for one.
        if let feedback = root["promptFeedback"] as? [String: Any],
            let reason = feedback["blockReason"] as? String
        {
            throw ModelError.refused(id, category: reason, explanation: nil)
        }

        guard let candidate = (root["candidates"] as? [[String: Any]])?.first else {
            throw ModelError.malformed(id, "no candidates in the response")
        }

        let finish = candidate["finishReason"] as? String
        if let finish, Self.refusalReasons.contains(finish) {
            throw ModelError.refused(id, category: finish, explanation: nil)
        }
        if finish == "MAX_TOKENS" { throw ModelError.truncated(id) }

        // The answer can arrive split across several parts; concatenating is
        // the documented way to reassemble it.
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else {
            throw ModelError.malformed(id, "no text part in the reply")
        }
        return text
    }
}
