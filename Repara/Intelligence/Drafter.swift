import Foundation
import ReparaCore

/// One Claude API call per report. Not an agent, not tool use, not MCP.
///
/// In goes the photo, the bundled type list and whatever the user said in any
/// language. Out comes a validated `{tipo_id, descricao}` — the description in
/// Portuguese, because a council worker reads it.
///
/// There is no official Anthropic Swift SDK, so this is `URLSession` against
/// the Messages API directly.
struct Drafter {

    // MARK: Configuration

    /// This is a narrow structured-extraction task, so `claude-sonnet-5` is
    /// worth measuring against this once it works — likely indistinguishable
    /// here and cheaper per report.
    static let model = "claude-opus-5"

    /// Picking the wrong one of 127 types routes the report to the wrong
    /// council department, so this starts high. `medium` and `low` are strong
    /// on this model and worth measuring — a report costs a few cents either
    /// way, and they get filed about once a fortnight.
    static let effort = "high"

    /// Thinking is **on by default** on Claude Opus 5, and `max_tokens` caps
    /// thinking plus response text together. The answer itself is a couple of
    /// hundred tokens; the rest of this is headroom so a long deliberation
    /// cannot truncate the JSON.
    static let maxTokens = 8000

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    /// Server-side fallback: if the safety classifiers decline a request, the
    /// API re-runs it on the recommended model rather than handing back a
    /// refusal. Cheap insurance for someone standing in the street with a
    /// photo — a spurious refusal there is a dead end, not an inconvenience.
    private static let fallbackBeta = "server-side-fallback-2026-07-01"

    // MARK: Errors

    enum DrafterError: Error, CustomStringConvertible {
        case missingAPIKey
        case refused(category: String?, explanation: String?)
        case truncated
        case http(status: Int, body: String)
        case malformed(String)
        case unknownType(Int)

        var description: String {
            switch self {
            case .missingAPIKey:
                return """
                    No Claude API key stored. Add one in Settings — it stays in the Keychain \
                    and never leaves this phone except to api.anthropic.com.
                    """
            case let .refused(category, explanation):
                let detail = [category, explanation].compactMap { $0 }.joined(separator: ": ")
                return """
                    Claude declined to draft this report\(detail.isEmpty ? "" : " (\(detail))"). \
                    Write the description yourself and pick a type — everything else still works.
                    """
            case .truncated:
                return "The draft was cut off before it finished. Try again."
            case let .http(status, body):
                return "The Claude API returned \(status). \(body.prefix(200))"
            case let .malformed(detail):
                return "Could not read Claude's reply: \(detail)"
            case let .unknownType(id):
                return "Claude suggested report type \(id), which is not in the bundled list."
            }
        }
    }

    // MARK: The draft

    struct Draft: Equatable, Sendable {
        var type: TipoOcorrencia
        /// Portuguese, because a council worker reads it.
        var descricao: String
        var confidence: Confidence
        /// Anything worth telling the user before they file — a possible
        /// duplicate, an ambiguity, a reason to move the pin.
        var notesForUser: String?

        enum Confidence: String, Codable, Sendable {
            case high, medium, low
        }
    }

    // MARK: Request

    /// Draft a report from a photo and whatever the user said.
    ///
    /// - Parameters:
    /// Duplicates are **not** judged here — see `judgeDuplicates`. They cannot
    /// be: the nearby reports are resolved from the occurrence type, and the
    /// type is what this call produces, so at this point there is nothing to
    /// compare against.
    ///
    /// - Parameters:
    ///   - photo: **The downscaled copy**, not the original. See `PhotoScaler`:
    ///     ~1568 px is plenty to identify a dumped mattress and costs a
    ///     fraction of the tokens. The full-resolution original goes to the
    ///     council; these are two sizes for two purposes.
    ///   - address: For the same reason, `AppModel` has no address to pass yet
    ///     — resolving one also needs the type. It is honoured when a caller
    ///     does have one.
    func draft(
        photo: Data,
        userText: String,
        address: String?,
        taxonomy: Taxonomy = .bundled
    ) async throws -> Draft {
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": Self.maxTokens,
            "fallbacks": "default",
            "system": Self.systemPrompt,
            "output_config": [
                "effort": Self.effort,
                "format": [
                    "type": "json_schema",
                    "schema": Self.schema(for: taxonomy),
                ],
            ],
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": photo.base64EncodedString(),
                            ],
                        ],
                        [
                            "type": "text",
                            "text": Self.userPrompt(
                                userText: userText,
                                address: address,
                                taxonomy: taxonomy
                            ),
                        ],
                    ],
                ]
            ],
        ]

        return try Self.parse(
            try await Self.send(body, betas: [Self.fallbackBeta]), taxonomy: taxonomy)
    }

    // MARK: Transport

    /// - Parameter betas: Sent as `anthropic-beta`, and only when non-empty —
    ///   a beta header names a request shape, so it belongs on the calls that
    ///   actually use that shape rather than on every call by default.
    private static func send(_ body: [String: Any], betas: [String]) async throws -> Data {
        guard let apiKey = Keychain.get(.claudeAPIKey), !apiKey.isEmpty else {
            throw DrafterError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if !betas.isEmpty {
            request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DrafterError.malformed("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DrafterError.http(
                status: http.statusCode,
                body: String(data: data.prefix(2000), encoding: .utf8) ?? ""
            )
        }
        return data
    }

    /// The text of a structured-output response, after the checks that have to
    /// happen before `content` can be indexed.
    ///
    /// Check `stop_reason` before reading content: on a refusal the content
    /// array is empty or partial, and indexing it unconditionally crashes.
    private static func structuredText(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DrafterError.malformed("response was not a JSON object")
        }

        let stopReason = root["stop_reason"] as? String
        if stopReason == "refusal" {
            let details = root["stop_details"] as? [String: Any]
            throw DrafterError.refused(
                category: details?["category"] as? String,
                explanation: details?["explanation"] as? String
            )
        }
        if stopReason == "max_tokens" { throw DrafterError.truncated }

        guard let content = root["content"] as? [[String: Any]],
            let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else {
            throw DrafterError.malformed("no text block in the response")
        }
        return text
    }

    // MARK: Response

    private static func parse(_ data: Data, taxonomy: Taxonomy) throws -> Draft {
        let text = try structuredText(data)

        struct Payload: Decodable {
            let tipo_id: Int
            let descricao: String
            let confidence: Draft.Confidence
            let notes_for_user: String?
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: Data(text.utf8))
        } catch {
            throw DrafterError.malformed(String(describing: error))
        }

        // The schema constrains tipo_id to the bundled ids, so this should be
        // unreachable — but the failure it prevents is a report filed against
        // the wrong department, so it is checked rather than assumed.
        guard let type = taxonomy.type(id: payload.tipo_id) else {
            throw DrafterError.unknownType(payload.tipo_id)
        }

        // Structured-output schemas cannot express maxLength, so the portal's
        // 2000-character limit is enforced here instead.
        let descricao = String(
            payload.descricao.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(Submitter.maxDescription))

        return Draft(
            type: type,
            descricao: descricao,
            confidence: payload.confidence,
            notesForUser: payload.notes_for_user?.isEmpty == false ? payload.notes_for_user : nil
        )
    }

    // MARK: Duplicate judgement

    struct DuplicateVerdict: Equatable, Sendable {
        /// 1-based positions in the `nearBy` list that was sent.
        var matches: [Int]
        /// One sentence for the reporter. `nil` when nothing matched.
        var reason: String?
    }

    /// Has somebody already reported this?
    ///
    /// A second call rather than part of the draft, because the nearby reports
    /// do not exist yet when the draft is made: resolving them needs the
    /// occurrence type, and the type is what the draft produces. It costs the
    /// council nothing — `prepare` has already fetched `nearBy` — and it only
    /// fires when there is something nearby to compare against, so most reports
    /// never make this call at all.
    ///
    /// The deterministic check in `ReparaCore` only matches the **same type
    /// id**. The same pothole filed as "Pavimento danificado" and as "Buraco na
    /// via" is two ids and one hole; reading the descriptions is what catches
    /// that, and it is the reason this call is worth making.
    ///
    /// Only `promptSummary` is sent, and the answer comes back as positions in
    /// the list rather than occurrence numbers — somebody else's report number
    /// is theirs, and nothing here needs it.
    func judgeDuplicates(
        descricao: String,
        type: TipoOcorrencia,
        address: String?,
        nearBy: [NearByOccurrence]
    ) async throws -> DuplicateVerdict {
        guard !nearBy.isEmpty else { return DuplicateVerdict(matches: [], reason: nil) }

        // No `fallbacks` here, unlike the draft. Server-side fallback is
        // documented for the Opus tier, and a refusal on this call is not a
        // dead end anyway: `AppModel` clears the verdict, the deterministic
        // 50 m check still stands, and filing is unaffected.
        let body: [String: Any] = [
            "model": Self.judgeModel,
            "max_tokens": Self.judgeMaxTokens,
            "system": Self.judgeSystemPrompt,
            "output_config": [
                "effort": Self.judgeEffort,
                "format": [
                    "type": "json_schema",
                    "schema": Self.judgeSchema,
                ],
            ],
            "messages": [
                [
                    "role": "user",
                    "content": Self.judgePrompt(
                        descricao: descricao, type: type, address: address, nearBy: nearBy),
                ]
            ],
        ]

        let text = try Self.structuredText(try await Self.send(body, betas: []))

        struct Payload: Decodable {
            let duplicate_of: [Int]
            let reason: String?
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: Data(text.utf8))
        } catch {
            throw DrafterError.malformed(String(describing: error))
        }

        // A schema cannot express "a valid position in the list", so anything
        // outside it is dropped rather than trusted into an index.
        let matches = Set(payload.duplicate_of.filter { (1...nearBy.count).contains($0) }).sorted()
        let reason = payload.reason?.trimmingCharacters(in: .whitespacesAndNewlines)

        return DuplicateVerdict(
            matches: matches,
            reason: matches.isEmpty || reason?.isEmpty != false ? nil : reason
        )
    }

    /// Sonnet rather than the draft's Opus, at the user's direction. This is a
    /// short text comparison of a few sentences against at most eight more —
    /// far narrower than picking one of 127 types from a photograph — and its
    /// wrong answers are the cheap kind to notice, because the reports it is
    /// comparing sit on screen next to its verdict.
    static let judgeModel = "claude-sonnet-5"

    /// Likewise this does not need the draft's `high`. `low` is worth measuring
    /// against it.
    static let judgeEffort = "medium"

    /// Thinking counts against this too, and the answer is a handful of
    /// integers, so the rest is headroom.
    static let judgeMaxTokens = 4000

    private static let judgeSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "duplicate_of": [
                "type": "array",
                "items": ["type": "integer"],
                "description":
                    "The numbers, as listed, of the nearby reports that describe the same physical "
                    + "problem as the new one. Empty if none of them do.",
            ],
            "reason": [
                "type": "string",
                "description":
                    "One sentence for the reporter saying why it looks like the same problem. "
                    + "Empty if nothing matched.",
            ],
        ],
        "required": ["duplicate_of", "reason"],
        "additionalProperties": false,
    ]

    private static let judgeSystemPrompt = """
        You are checking whether a problem somebody is about to report to Lisbon's city council \
        has already been reported by someone else.

        You get the new report, and a numbered list of reports already open or recently closed \
        nearby with how far away each one is. Decide which of them, if any, describe the same \
        physical problem in the same place.

        Compare what is described, not which category it was filed under. The same problem is \
        often filed under different report types — a damaged road surface and a hole in the \
        carriageway are two types and one hole. Two problems of the same kind a few doors apart \
        are not the same problem.

        Getting this wrong costs something either way: a duplicate wastes a council worker's trip, \
        and a wrong flag talks somebody out of reporting a real problem. Flag a report when it \
        plausibly describes the same thing. If you are unsure, still flag it, and say what you are \
        unsure about in the reason — the reporter can see both reports and decides.
        """

    private static func judgePrompt(
        descricao: String,
        type: TipoOcorrencia,
        address: String?,
        nearBy: [NearByOccurrence]
    ) -> String {
        var lines = ["The new report:", "Type: \(type.descricao) (\(type.area))"]
        if let address, !address.isEmpty { lines.append("Address: \(address)") }
        lines.append("Description: \(descricao)")

        // `promptSummary` is written as a bullet; numbering it is what lets the
        // answer come back as positions instead of occurrence numbers.
        let list = nearBy.enumerated().map { index, occurrence -> String in
            let summary = occurrence.promptSummary
            let body = summary.hasPrefix("- ") ? String(summary.dropFirst(2)) : summary
            return "\(index + 1). \(body)"
        }.joined(separator: "\n")

        return lines.joined(separator: "\n") + "\n\nReports already nearby:\n\(list)"
    }

    // MARK: Schema

    /// Constraining `tipo_id` to the bundled ids makes an invalid type
    /// structurally impossible rather than merely unlikely. The schema is
    /// stable (the taxonomy is bundled), so it stays in the API's 24-hour
    /// schema cache and costs nothing after the first call.
    private static func schema(for taxonomy: Taxonomy) -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "tipo_id": [
                    "type": "integer",
                    "description": "The id of the occurrence type, from the list provided.",
                    "enum": taxonomy.types.map(\.id),
                ],
                "descricao": [
                    "type": "string",
                    "description":
                        "What is wrong, in European Portuguese, for a council worker to read. "
                        + "One or two sentences. Under 2000 characters.",
                ],
                "confidence": [
                    "type": "string",
                    "enum": ["high", "medium", "low"],
                    "description": "How sure you are of the type and the description.",
                ],
                "notes_for_user": [
                    "type": "string",
                    "description":
                        "Anything the reporter should know before filing — an ambiguity between "
                        + "types, a reason to move the map pin. Duplicates are checked separately, "
                        + "so do not guess at them here. Empty if there is nothing worth saying.",
                ],
            ],
            "required": ["tipo_id", "descricao", "confidence", "notes_for_user"],
            "additionalProperties": false,
        ]
    }

    // MARK: Prompts

    private static let systemPrompt = """
        You help a Lisbon resident file a report with Na Minha Rua LX, the city council's \
        problem-reporting service. You see a photograph of the problem and whatever the person \
        said about it, in any language.

        Two things matter.

        First, the report type. There are 127 of them and they route to different council \
        departments, so the wrong one sends the report to the wrong desk. Several types are \
        worded similarly across departments — read the area each belongs to before choosing. If \
        two are genuinely plausible, pick the better one and say so in notes_for_user.

        Second, the description. Write it in European Portuguese (pt-PT, not Brazilian) because \
        a council worker reads it and acts on it. Describe what is wrong and what is visible in \
        the photo, plainly and specifically — "sacos de lixo abandonados no passeio junto ao \
        número 12", not "há lixo". One or two sentences. No greeting, no signature, no request \
        for a reply. Do not invent details you cannot see; if the person told you something the \
        photo does not show, you may use it, but do not embellish beyond both.

        Do not describe people, faces, or vehicle number plates, and do not include them in the \
        description even if they are visible.
        """

    private static func userPrompt(
        userText: String,
        address: String?,
        taxonomy: Taxonomy
    ) -> String {
        var sections: [String] = []

        if let address, !address.isEmpty {
            sections.append("The map pin currently resolves to: \(address)")
        }

        let said = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append(
            said.isEmpty
                ? "The person said nothing — go on the photograph alone."
                : "The person said (any language):\n\(said)")

        let types = taxonomy.areas.map { area -> String in
            let rows = taxonomy.types(inArea: area.id)
                .map { "  \($0.id)  \($0.descricao)\($0.en.map { " — \($0)" } ?? "")" }
                .joined(separator: "\n")
            return "\(area.descricao)\n\(rows)"
        }.joined(separator: "\n\n")

        sections.append("The report types, grouped by council area:\n\n\(types)")
        return sections.joined(separator: "\n\n")
    }
}
