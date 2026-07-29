import Foundation

/// Chat Completions, over `URLSession`.
///
/// Chat Completions rather than the Responses API because it is the shape
/// every OpenAI-compatible server also speaks — pointing this at a local or
/// third-party endpoint later is a base-URL change, not a rewrite.
struct OpenAIProvider: ModelProvider {

    let id = ModelProviderID.openAI

    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    func complete(_ request: ModelRequest) async throws -> String {
        let apiKey = try ModelTransport.apiKey(for: id)

        var content: [[String: Any]] = [["type": "text", "text": request.userText]]
        if let image = request.image {
            // No separate image block type here: the data URI *is* the URL.
            content.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:image/jpeg;base64,\(image.base64EncodedString())"
                ],
            ])
        }

        let body: [String: Any] = [
            "model": request.model,
            "max_completion_tokens": request.maxTokens,
            "reasoning_effort": request.effort.rawValue,
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": request.schemaName,
                    // Same guarantee as Anthropic's structured outputs, and it
                    // needs exactly what our schemas already declare:
                    // `additionalProperties: false` and every property required.
                    "strict": true,
                    "schema": request.schema,
                ],
            ],
            "messages": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": content],
            ],
        ]

        return try text(from: try await send(body, apiKey: apiKey))
    }

    // MARK: Transport

    /// `reasoning_effort` and `max_completion_tokens` are accepted by the
    /// reasoning models and rejected by the older chat ones, and which is
    /// which is not something this app can know — the model id is free text a
    /// user typed into Settings.
    ///
    /// So rather than guess from the id, send the modern shape and degrade if
    /// the API says it does not understand a parameter. Two degradations, one
    /// retry each, then give up and surface the error.
    private func send(_ body: [String: Any], apiKey: String) async throws -> Data {
        var body = body
        var attemptsLeft = 3

        while true {
            attemptsLeft -= 1
            do {
                return try await post(body, apiKey: apiKey)
            } catch let error as ModelError {
                guard case let .http(_, status, message) = error,
                    status == 400,
                    attemptsLeft > 0,
                    let degraded = Self.degrade(body, complaint: message)
                else { throw error }
                body = degraded
            }
        }
    }

    private func post(_ body: [String: Any], apiKey: String) async throws -> Data {
        var http = URLRequest(url: Self.endpoint)
        http.httpMethod = "POST"
        http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        http.setValue("application/json", forHTTPHeaderField: "content-type")
        http.timeoutInterval = ModelTransport.timeout
        http.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await ModelTransport.send(http, provider: id)
    }

    /// `nil` when the complaint is about something we cannot fix by dropping a
    /// parameter — a bad model id, a malformed schema, an unaffordable request.
    private static func degrade(_ body: [String: Any], complaint: String) -> [String: Any]? {
        var body = body
        if complaint.contains("reasoning_effort"), body["reasoning_effort"] != nil {
            body["reasoning_effort"] = nil
            return body
        }
        if complaint.contains("max_completion_tokens"), let max = body["max_completion_tokens"] {
            body["max_completion_tokens"] = nil
            body["max_tokens"] = max
            return body
        }
        return nil
    }

    // MARK: Response

    private func text(from data: Data) throws -> String {
        let root = try ModelTransport.json(data, provider: id)

        guard let choice = (root["choices"] as? [[String: Any]])?.first else {
            throw ModelError.malformed(id, "no choices in the response")
        }
        guard let message = choice["message"] as? [String: Any] else {
            throw ModelError.malformed(id, "no message in the first choice")
        }

        // A refusal is a field on the message, not an HTTP error, and it comes
        // back *instead of* content — so it has to be checked before reading.
        if let refusal = message["refusal"] as? String, !refusal.isEmpty {
            throw ModelError.refused(id, category: nil, explanation: refusal)
        }
        if choice["finish_reason"] as? String == "length" {
            throw ModelError.truncated(id)
        }

        guard let text = message["content"] as? String, !text.isEmpty else {
            throw ModelError.malformed(id, "no content in the reply")
        }
        return text
    }
}
