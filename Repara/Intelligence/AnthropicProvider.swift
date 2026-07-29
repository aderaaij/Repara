import Foundation

/// The Messages API, over `URLSession` — there is no official Anthropic Swift
/// SDK.
///
/// This is the shape the app was built against and the one the payload quirks
/// were established on, so it is deliberately a straight translation of
/// `ModelRequest` rather than anything clever.
struct AnthropicProvider: ModelProvider {

    let id = ModelProviderID.anthropic

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    /// Server-side fallback: if the safety classifiers decline a request, the
    /// API re-runs it on the recommended model rather than handing back a
    /// refusal. Cheap insurance for someone standing in the street with a
    /// photo — a spurious refusal there is a dead end, not an inconvenience.
    private static let fallbackBeta = "server-side-fallback-2026-07-01"

    func complete(_ request: ModelRequest) async throws -> String {
        let apiKey = try ModelTransport.apiKey(for: id)

        var content: [[String: Any]] = []
        if let image = request.image {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": image.base64EncodedString(),
                ],
            ])
        }
        content.append(["type": "text", "text": request.userText])

        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens,
            "system": request.system,
            "output_config": [
                "effort": request.effort.rawValue,
                "format": [
                    "type": "json_schema",
                    "schema": request.schema,
                ],
            ],
            "messages": [["role": "user", "content": content]],
        ]
        if request.allowFallbacks {
            body["fallbacks"] = "default"
        }

        var http = URLRequest(url: Self.endpoint)
        http.httpMethod = "POST"
        http.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        http.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        http.setValue("application/json", forHTTPHeaderField: "content-type")
        // A beta header names a request shape, so it belongs on the calls that
        // actually use that shape rather than on every call by default.
        if request.allowFallbacks {
            http.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        http.timeoutInterval = ModelTransport.timeout
        http.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try text(from: try await ModelTransport.send(http, provider: id))
    }

    /// Check `stop_reason` before reading content: on a refusal the content
    /// array is empty or partial, and indexing it unconditionally crashes.
    private func text(from data: Data) throws -> String {
        let root = try ModelTransport.json(data, provider: id)

        let stopReason = root["stop_reason"] as? String
        if stopReason == "refusal" {
            let details = root["stop_details"] as? [String: Any]
            throw ModelError.refused(
                id,
                category: details?["category"] as? String,
                explanation: details?["explanation"] as? String
            )
        }
        if stopReason == "max_tokens" { throw ModelError.truncated(id) }

        guard let content = root["content"] as? [[String: Any]],
            let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else {
            throw ModelError.malformed(id, "no text block in the response")
        }
        return text
    }
}
