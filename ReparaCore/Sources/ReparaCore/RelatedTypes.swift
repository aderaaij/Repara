import Foundation

// MARK: - Relations

/// How one occurrence type relates to another that could hold the same problem.
///
/// The distinction is not cosmetic — it decides whether the app spends requests
/// on its own initiative. See `Taxonomy.related(to:)`.
public enum TypeRelation: String, Sendable, Hashable, Codable, CaseIterable {

    /// The other type is how somebody **asks** the council to come and take this
    /// away. An open one means the problem is already booked in, and a complaint
    /// filed on top of it sends a second worker to a job that is already on
    /// somebody's list.
    ///
    /// This is the mattress case: one resident books a bulky-waste collection
    /// (`Remoção-Monstros-Pedido de recolha`) and puts the mattress out; a
    /// passer-by sees an abandoned mattress and files `Entulhos, objetos
    /// volumosos […] abandonados na via pública`. Two type ids, one mattress,
    /// and the second report buys nothing.
    case collectedByRequest

    /// The same physical problem, filed under a different type — usually because
    /// two departments word their categories alike, or because the pin decides
    /// which of them applies and the pin is a judgement call.
    case sameProblem
}

/// Another type worth looking under, and why.
public struct RelatedType: Sendable, Hashable, Identifiable {
    public let type: TipoOcorrencia
    public let relation: TypeRelation

    public var id: Int { type.id }

    public init(type: TipoOcorrencia, relation: TypeRelation) {
        self.type = type
        self.relation = relation
    }
}

// MARK: - Clusters

/// A set of types that can hold the same physical problem.
///
/// Clusters may overlap: a type appears in as many as apply, and
/// `Taxonomy.related(to:)` unions them. That is deliberate — a hole at a kerb
/// belongs to both the pavement cluster and the carriageway one, and forcing a
/// single home for it would mean choosing which half of the confusion to miss.
struct TypeCluster: Sendable {
    /// Types somebody files to complain that something is wrong.
    let problems: [Int]
    /// Types somebody files to ask the council to come and deal with it.
    /// Reaching one of these **from** a problem is `.collectedByRequest`.
    let requests: [Int]

    init(problems: [Int], requests: [Int] = []) {
        self.problems = problems
        self.requests = requests
    }

    /// Every other member, in declaration order, with the relation it holds
    /// *from* `id`. Nil when `id` is not in this cluster.
    ///
    /// Declaration order only; `Taxonomy.related(to:)` is what promotes
    /// `.collectedByRequest` to the front. Ordering here as well would put the
    /// other collection requests above the complaints when the caller *is* a
    /// collection request — and somebody booking a mattress collection wants to
    /// know whether it has already been reported as fly-tipping, not which other
    /// collections exist.
    func members(from id: Int) -> [(id: Int, relation: TypeRelation)]? {
        let isProblem = problems.contains(id)
        guard isProblem || requests.contains(id) else { return nil }

        let ordered =
            problems.map { ($0, TypeRelation.sameProblem) }
            + requests.map { ($0, isProblem ? TypeRelation.collectedByRequest : .sameProblem) }
        return ordered.filter { $0.0 != id }.map { (id: $0.0, relation: $0.1) }
    }
}

// MARK: - The curated table

/// The hand-written half of the map.
///
/// **Deliberately incomplete.** Every entry here is a claim that two types can
/// hold one physical problem, and a wrong claim spends a municipal request to
/// show somebody an irrelevant report. Missing a pair costs nothing but the
/// warning nobody got, so this errs towards leaving pairs out. Add them as they
/// turn up in real use.
///
/// The other half is derived and needs no curation: five descriptions are
/// worded *identically* across two areas, and those are confusable by
/// definition — see `Taxonomy.collisions`.
///
/// Ids are checked against the bundled taxonomy by `RelatedTypeTests`, so
/// regenerating `taxonomy.json` cannot silently leave a dangling id here.
enum CuratedClusters {
    static let all: [TypeCluster] = [

        // MARK: Higiene Urbana — dumping vs collection requests

        // The mattress. Somebody books a collection and puts the thing out;
        // somebody else walks past and reports fly-tipping.
        TypeCluster(
            problems: [
                97,  // Entulhos, objetos volumosos, resíduos de jardim ou perigosos abandonados
                262,  // Sacos ou outros lixos abandonados
                430,  // Outras situações de sacos, pilhões, fitas ou papeleiras
            ],
            requests: [
                256,  // Remoção-Monstros-Pedido de recolha
                257,  // Remoção-RCD-Pedido de recolha
                258,  // Remoção-Jardins-Pedido de recolha
                259,  // Remoção Seletivas - Remoção pontual de papel/cartão
            ]
        ),

        // A container standing in the street reads as abandoned. It may be there
        // with written permission, or already booked to be taken away.
        TypeCluster(
            problems: [
                446,  // Contentor de pequena capacidade (2 rodas) abandonado na via
                447,  // Contentor coletivo (4 rodas) fora do local
                452,  // Contentores na via pública fora do horário regulamentar
            ],
            requests: [
                435,  // Pedido de autorização para manter contentor na via pública
                456,  // Pedido de retirada ou devolução de contentor de média capacidade
            ]
        ),

        // An overflowing bin: a complaint about the mess, or a request to empty it.
        TypeCluster(
            problems: [
                445,  // Falta de despejo do contentor de pequena capacidade ou sacos
                265,  // Reclamações no âmbito da recolha diária de resíduos sólidos urbanos
            ],
            requests: [
                426  // Pedido de despejo de contentor coletivo (4 rodas)
            ]
        ),

        // Rubbish piled around a recycling point, which is the same event as the
        // recycling point being full.
        TypeCluster(
            problems: [
                55,  // Resíduos em torno de ecoponto e vidrões
                442,  // Substituição ou reparação de ecoponto, vidrão ou ecoilha danificados
            ],
            requests: [
                414,  // Pedido de despejo de ecoponto ou vidrão
                415,  // Lavagem de ecoponto ou vidrão
            ]
        ),

        // MARK: Holes and surfaces

        // Pavement. `Abatimentos superficiais` also collides by wording with its
        // Estradas twin, which the derived half picks up for free.
        TypeCluster(problems: [953, 506, 1262]),
        // Carriageway.
        TypeCluster(problems: [36, 660, 1010]),
        // The kerb is where the two meet, and where the pin is a judgement call.
        TypeCluster(problems: [953, 36, 660]),

        // MARK: Iluminação Pública

        // A dark street is usually one dark lamp, filed at either scale.
        TypeCluster(problems: [73, 74, 1151]),
        TypeCluster(problems: [74, 1149, 1150]),

        // MARK: Saneamento

        TypeCluster(problems: [136, 140, 139, 134]),

        // MARK: Cross-department pairs

        // Insalubridade is a Higiene Urbana complaint and a Segurança Pública
        // enforcement matter, worded almost alike and routed to two departments.
        TypeCluster(problems: [99, 1138]),

        // A vehicle that has not moved in a month, seen two ways.
        TypeCluster(problems: [485, 12]),

        // Weeds on a pavement are Higiene Urbana; the same greenery is Árvores
        // e Espaços Verdes.
        TypeCluster(problems: [1102, 30]),

        // MARK: Animals

        TypeCluster(problems: [476, 479, 463]),
    ]
}

// MARK: - Lookup

extension Taxonomy {

    /// How many other types one report may cost the portal a look under.
    ///
    /// This is a request budget against a municipal server, not a display limit,
    /// which is why it lives here rather than in a view. One report resolves to
    /// one `getGeoAttributes` call today; this caps the worst case at four.
    public static let maxRelatedLookups = 3

    /// Other types that could hold the same physical problem as `type`.
    ///
    /// Ordered `.collectedByRequest` first — those are the ones worth spending a
    /// request on unasked — then `.sameProblem`, and within each by the order the
    /// clusters declare, which is written most-confusable first. Capped at
    /// `maxRelatedLookups`, because each entry is a request to the council's
    /// server.
    ///
    /// Ids that are not in this taxonomy are dropped rather than trapped: a
    /// regenerated `taxonomy.json` that retires a type should cost a warning,
    /// not a crash in somebody's hand. `RelatedTypeTests` asserts that none are
    /// currently dropped.
    public func related(to type: TipoOcorrencia, matching relation: TypeRelation? = nil)
        -> [RelatedType]
    {
        var strongest: [Int: TypeRelation] = [:]
        var order: [Int] = []

        func note(_ id: Int, _ found: TypeRelation) {
            guard id != type.id else { return }
            if let existing = strongest[id] {
                // `.collectedByRequest` is the one that changes what the app
                // does, so it wins wherever two clusters disagree.
                if existing == .collectedByRequest { return }
                strongest[id] = found
            } else {
                strongest[id] = found
                order.append(id)
            }
        }

        for cluster in CuratedClusters.all {
            guard let members = cluster.members(from: type.id) else { continue }
            for member in members { note(member.id, member.relation) }
        }
        // Identical wording across two areas: confusable by construction, and
        // free — no curation to keep in step with the taxonomy.
        for id in collisions[type.id] ?? [] { note(id, .sameProblem) }

        let resolved = order.compactMap { id -> RelatedType? in
            guard let found = strongest[id], let resolved = self.type(id: id) else { return nil }
            guard relation == nil || relation == found else { return nil }
            return RelatedType(type: resolved, relation: found)
        }

        // Partitioned rather than sorted: `sorted(by:)` is not guaranteed stable
        // in Swift, and declaration order inside each group is the whole of what
        // "most confusable first" means here.
        let ranked =
            resolved.filter { $0.relation == .collectedByRequest }
            + resolved.filter { $0.relation == .sameProblem }

        return Array(ranked.prefix(Self.maxRelatedLookups))
    }
}
