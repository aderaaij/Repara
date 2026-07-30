import Foundation
import ReparaCore

/// One model call per report — two only when the first answer has to be sent
/// back, see `readsAsDeliberation`. Not an agent, not tool use, not MCP.
///
/// In goes the photo, the bundled type list and whatever the user said in any
/// language. Out comes a validated `{tipo_id, descricao}` — the description in
/// Portuguese, because a council worker reads it.
///
/// **Which service answers is not this file's business.** Everything here is
/// the part that stays the same whoever does: the prompts, the schemas, and
/// the validation that turns a plausible-looking reply into something safe to
/// file. `ModelProvider` owns the wire format; see `ModelSettings` for the
/// selected provider and its models.
struct Drafter {

    // MARK: Configuration

    /// Picking the wrong one of 127 types routes the report to the wrong
    /// council department, so this starts high. `medium` and `low` are worth
    /// measuring — a report costs a few cents either way, and they get filed
    /// about once a fortnight.
    static let effort = ModelRequest.Effort.high

    /// Reasoning tokens count against the output cap on every provider. The
    /// answer itself is a couple of hundred tokens; the rest of this is
    /// headroom so a long deliberation cannot truncate the JSON.
    static let maxTokens = 8000

    // MARK: Errors

    /// Only the failures that are about *this app's* rules. Everything to do
    /// with reaching a model — missing keys, refusals, truncation, HTTP — is
    /// `ModelError`, so that adding a provider does not add an error type.
    enum DrafterError: Error, CustomStringConvertible {
        case unknownType(Int)

        var description: String {
            switch self {
            case let .unknownType(id):
                return "The model suggested report type \(id), which is not in the bundled list."
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
        // Read once and used for both the model id and the transport:
        // resolving `ModelSettings.provider` twice could, in principle, send
        // one provider's model id to another's endpoint.
        let selected = ModelSettings.provider
        let model = ModelSettings.draftModel(for: selected)

        // Inert unless the build is a debug one launched with `--reuse-drafts`.
        // See `DraftCache`: re-picking the same photo in a real report is a
        // request for a *different* answer, not for this one again.
        let cacheKey = DraftCache.key(
            photo: photo, userText: userText, provider: selected, model: model)
        if let cached = DraftCache.draft(forKey: cacheKey, taxonomy: taxonomy) { return cached }

        let first = try await ask(
            selected, model: model, photo: photo, userText: userText, address: address,
            taxonomy: taxonomy, retryNote: nil)
        guard Self.readsAsDeliberation(first.descricao) else {
            DraftCache.store(first, forKey: cacheKey)
            return first
        }

        // Ask once more, saying what was wrong with the last answer. It costs a
        // model call and no portal request, and the alternative — picking which
        // paragraph of the working-out was meant to be the description — is a
        // guess about the sentence a council worker acts on.
        //
        // A failure on the retry is not a failure of the draft: the first
        // answer is still there, so a thrown error here would lose a usable
        // type to fix a description.
        let second = try? await ask(
            selected, model: model, photo: photo, userText: userText, address: address,
            taxonomy: taxonomy, retryNote: Self.retryNote)
        if let second, !Self.readsAsDeliberation(second.descricao) {
            DraftCache.store(second, forKey: cacheKey)
            return second
        }

        // Not cached: a flagged draft is the one answer worth paying to ask
        // again, and re-using it would make the working-out sticky.
        return Self.flagged(first)
    }

    /// One attempt. `retryNote` is empty on the first and says what came back
    /// wrong on the second.
    private func ask(
        _ provider: ModelProviderID,
        model: String,
        photo: Data,
        userText: String,
        address: String?,
        taxonomy: Taxonomy,
        retryNote: String?
    ) async throws -> Draft {
        let request = ModelRequest(
            model: model,
            system: Self.systemPrompt,
            userText: Self.userPrompt(
                userText: userText,
                address: address,
                taxonomy: taxonomy,
                retryNote: retryNote
            ),
            image: photo,
            schema: Self.schema(for: taxonomy),
            schemaName: "repara_draft",
            maxTokens: Self.maxTokens,
            effort: Self.effort,
            // Only the draft asks for a fallback: a refusal here strands
            // somebody in the street, whereas a refused judgement just clears
            // the verdict. Providers without one ignore the flag.
            allowFallbacks: true
        )

        let text = try await provider.makeProvider().complete(request)
        return try Self.parse(text, taxonomy: taxonomy, provider: provider)
    }

    // MARK: Response

    private static func parse(
        _ text: String, taxonomy: Taxonomy, provider: ModelProviderID
    ) throws -> Draft {
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
            throw ModelError.malformed(provider, String(describing: error))
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

    // MARK: The working-out problem

    /// Does this read as the model's working-out rather than a report body?
    ///
    /// A structured-output schema does not stop a model deliberating *inside*
    /// one of its strings. A real reply arrived with a stray `{ }}`, an aside
    /// reading "Nota: consultar tipo 256 (Remoção-Monstros)" and the model's
    /// own "Descrição final:" heading — all of it in `descricao`, which is
    /// filed verbatim for a council worker to read.
    ///
    /// A schema cannot express "a description rather than an argument about
    /// one", so it is checked here, for the same reason `tipo_id` is resolved
    /// against the bundled taxonomy rather than trusted.
    ///
    /// Deliberately coarse. A false positive costs one more model call and
    /// nothing else — the caller re-asks and keeps the original either way — so
    /// the signals are the ones that cannot happen in a description a council
    /// worker would want to read. A false negative is the one that reaches the
    /// council.
    static func readsAsDeliberation(_ text: String) -> Bool {
        // Braces: JSON structure that escaped into the prose.
        if text.contains("{") || text.contains("}") { return true }

        let lines =
            text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // A blank line between two written ones. The prompt asks for one or two
        // sentences, so a paragraph break means the model stopped describing
        // the street and started explaining itself. Leading and trailing blank
        // lines are ordinary whitespace and say nothing.
        if let first = lines.firstIndex(where: { !$0.isEmpty }),
            let last = lines.lastIndex(where: { !$0.isEmpty }),
            lines[first...last].contains("")
        {
            return true
        }

        return lines.contains(where: Self.isMetaHeading)
    }

    /// The headings a model reaches for once it is narrating rather than
    /// describing.
    ///
    /// Written without accents and matched folded, so each appears once.
    private static let metaHeadings: Set<String> = [
        "nota", "notas", "observacao", "observacoes", "descricao",
        "descricao final", "analise", "conclusao", "resposta", "justificacao",
        "raciocinio", "tipo", "tipologia", "alternativa", "alternativas",
    ]

    /// Matched against the text before a line's **first colon**, and only
    /// against the listed headings — so "Buraco na via: cerca de 20 cm de
    /// profundidade", which is a description, matches nothing here.
    private static func isMetaHeading(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        let heading = line[..<colon]
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
        return metaHeadings.contains(heading)
    }

    /// Kept, not repaired.
    ///
    /// Choosing which paragraph of a deliberation was meant to be the report
    /// body would be a guess, and a wrong salvage is the dangerous kind: it
    /// reads as clean. So the text reaches the Review screen exactly as it
    /// arrived, at low confidence — which the screen already prints next to the
    /// type — with a note saying what to do about it.
    private static func flagged(_ draft: Draft) -> Draft {
        var out = draft
        out.confidence = .low
        out.notesForUser = ([Self.deliberationNote] + [draft.notesForUser].compactMap { $0 })
            .joined(separator: " ")
        return out
    }

    private static let deliberationNote =
        "This came back with the model's working-out in it rather than a description. "
        + "Read it and rewrite it before filing."

    /// Appended last, after the type list, so it is the most recent thing said.
    /// Only the second attempt sees it.
    private static let retryNote = """
        Your last reply put your working-out in descricao: a heading, an aside about another \
        type, a paragraph of reasoning. That field is filed verbatim and a council worker reads \
        it, so it must hold the description of the problem and nothing else — one or two \
        sentences, no headings, no notes, no alternatives weighed up. Anything you want the \
        reporter to know goes in notes_for_user instead.
        """

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

        // Read once and used for both the model id and the transport, so the
        // two can never come from different providers.
        let provider = ModelSettings.provider
        let request = ModelRequest(
            model: ModelSettings.judgeModel(for: provider),
            system: Self.judgeSystemPrompt,
            userText: Self.judgePrompt(
                descricao: descricao, type: type, address: address, nearBy: nearBy),
            // Text only. A photograph would tell the model nothing the
            // descriptions do not, and it doubles the cost of a call made
            // every time the pin moves onto a new set of reports.
            image: nil,
            schema: Self.judgeSchema,
            schemaName: "repara_duplicates",
            maxTokens: Self.judgeMaxTokens,
            effort: Self.judgeEffort,
            // No fallback here, unlike the draft: a refusal on this call is
            // not a dead end. `AppModel` clears the verdict, the deterministic
            // 50 m check still stands, and filing is unaffected.
            allowFallbacks: false
        )

        let text = try await provider.makeProvider().complete(request)

        struct Payload: Decodable {
            let duplicate_of: [Int]
            let reason: String?
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: Data(text.utf8))
        } catch {
            throw ModelError.malformed(provider, String(describing: error))
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

    /// A tier below the draft's, at the user's direction, on whichever
    /// provider is selected — see `ModelProviderID.defaultJudgeModel`. This is
    /// a short text comparison of a few sentences against at most eight more —
    /// far narrower than picking one of 127 types from a photograph — and its
    /// wrong answers are the cheap kind to notice, because the reports it is
    /// comparing sit on screen next to its verdict.
    ///
    /// Likewise it does not need the draft's `high`. `low` is worth measuring
    /// against it.
    static let judgeEffort = ModelRequest.Effort.medium

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

        You get the new report, and a numbered list of reports that are still open nearby, with \
        how far away each one is. Decide which of them, if any, describe the same physical \
        problem in the same place.

        Compare what is described, not which category it was filed under. The same problem is \
        often filed under different report types — a damaged road surface and a hole in the \
        carriageway are two types and one hole. Two problems of the same kind a few doors apart \
        are not the same problem.

        The list spans several report types, and some of them are requests rather than \
        complaints: a resident asking the council to come and collect something is how a mattress \
        legitimately ends up on a pavement. A request describing the same object is the same \
        thing, so flag it.

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

        descricao is filed word for word, so it holds the description and nothing else: no \
        heading, no note to the reporter, no second version of it, no reasoning about which type \
        to pick. Work that out before you answer, and put anything the reporter should know in \
        notes_for_user.

        Do not describe people, faces, or vehicle number plates, and do not include them in the \
        description even if they are visible.
        """

    private static func userPrompt(
        userText: String,
        address: String?,
        taxonomy: Taxonomy,
        retryNote: String? = nil
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
        if let retryNote { sections.append(retryNote) }
        return sections.joined(separator: "\n\n")
    }
}
