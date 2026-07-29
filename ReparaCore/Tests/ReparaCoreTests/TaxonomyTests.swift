import Foundation
import Testing

@testable import ReparaCore

@Suite("Taxonomy")
struct TaxonomyTests {

    @Test("the bundled taxonomy loads")
    func bundleLoads() {
        let taxonomy = Taxonomy.bundled
        #expect(taxonomy.types.count == 127)
        #expect(taxonomy.areas.count == 12)
        #expect(taxonomy.type(id: 262)?.descricao == "Sacos ou outros lixos abandonados")
    }

    @Test("every bundled type has a slug, an area and an English gloss")
    func bundleIsComplete() {
        for type in Taxonomy.bundled.types {
            #expect(!type.slug.isEmpty, "type \(type.id) has no slug")
            #expect(!type.area.isEmpty, "type \(type.id) has no area")
            #expect(type.en?.isEmpty == false, "type \(type.id) has no English gloss")
            #expect(type.slug == slugify(type.descricao) || type.slug.contains("--"))
        }
    }

    // MARK: Slugs

    @Test("slugify folds Portuguese diacritics")
    func slugs() {
        #expect(slugify("Sacos ou outros lixos abandonados") == "sacos-ou-outros-lixos-abandonados")
        #expect(slugify("Árvores e Espaços Verdes") == "arvores-e-espacos-verdes")
        #expect(slugify("Iluminação Pública") == "iluminacao-publica")
        #expect(slugify("  Manutenção ou reparação   ") == "manutencao-ou-reparacao")
        #expect(slugify("") == "")
    }

    // MARK: Resolution

    @Test("resolve accepts an id, an exact slug and a unique substring")
    func resolution() throws {
        let taxonomy = Taxonomy.bundled
        #expect(try taxonomy.resolve("262").id == 262)
        #expect(try taxonomy.resolve("sacos-ou-outros-lixos-abandonados").id == 262)
        #expect(try taxonomy.resolve("Sacos ou outros lixos abandonados").id == 262)
    }

    @Test("resolve matches the English gloss too")
    func englishGloss() throws {
        // Someone who does not read Portuguese should still find the right type.
        let graffiti = try Taxonomy.bundled.resolve("graffiti")
        #expect(graffiti.descricao.localizedCaseInsensitiveContains("grafiti"))
    }

    /// Five subcategories share wording across areas and route to different
    /// council departments. Guessing between them sends the report to the wrong
    /// desk, so an ambiguous match must be an error listing the candidates.
    @Test("resolve refuses to guess between ambiguous matches")
    func ambiguityRefused() throws {
        let ambiguous = ambiguousNeedle()
        let candidates = Taxonomy.bundled.search(ambiguous)
        #expect(candidates.count > 1, "\"\(ambiguous)\" should be genuinely ambiguous")

        #expect(throws: TaxonomyError.self) {
            _ = try Taxonomy.bundled.resolve(ambiguous)
        }

        // The error has to be actionable: it must name the candidates.
        do {
            _ = try Taxonomy.bundled.resolve(ambiguous)
            Issue.record("expected an ambiguity error")
        } catch let error as TaxonomyError {
            let message = error.description
            #expect(message.contains("different council departments"))
            for candidate in candidates.prefix(3) {
                #expect(message.contains(String(candidate.id)))
            }
        }
    }

    @Test("no match gives an actionable error rather than a silent nil")
    func noMatch() {
        #expect(throws: TaxonomyError.self) {
            _ = try Taxonomy.bundled.resolve("zzzzzzzz")
        }
        #expect(throws: TaxonomyError.self) {
            _ = try Taxonomy.bundled.resolve("999999")
        }
    }

    /// Every duplicated description in the live taxonomy must still resolve to
    /// exactly one type via its disambiguated slug, or the picker has entries
    /// the user cannot reach.
    @Test("duplicated descriptions still resolve uniquely by slug")
    func duplicatedDescriptions() throws {
        let taxonomy = Taxonomy.bundled
        let byDescription = Dictionary(grouping: taxonomy.types) { slugify($0.descricao) }
        let collisions = byDescription.filter { $0.value.count > 1 }
        #expect(!collisions.isEmpty, "the live taxonomy is known to contain collisions")

        for (_, types) in collisions {
            for type in types {
                #expect(
                    try taxonomy.resolve(type.slug).id == type.id,
                    "slug \(type.slug) should resolve to exactly type \(type.id)")
            }
        }
    }

    /// The other half of the same defect: the *shared wording* must refuse to
    /// guess. Only the first colliding type keeps the unsuffixed slug, so
    /// resolving the plain description would silently hand back whichever
    /// loaded first — and the live collisions span departments as different as
    /// Desporto and Educação.
    @Test("shared wording refuses to guess between departments")
    func sharedWordingRefuses() throws {
        let taxonomy = Taxonomy.bundled
        let collided = try #require(taxonomy.types.first { $0.slug.contains("--") })
        let siblings = taxonomy.types.filter {
            slugify($0.descricao) == slugify(collided.descricao)
        }
        #expect(siblings.count > 1)

        #expect(throws: TaxonomyError.self) {
            _ = try taxonomy.resolve(collided.descricao)
        }

        // The error is only useful if it names the areas that tell them apart.
        do {
            _ = try taxonomy.resolve(collided.descricao)
            Issue.record("expected the shared wording to be refused")
        } catch let error as TaxonomyError {
            for sibling in siblings {
                #expect(error.description.contains(sibling.area))
                #expect(error.description.contains(String(sibling.id)))
            }
        }
    }

    // MARK: Search

    @Test("search works in both languages and returns everything when empty")
    func search() {
        let taxonomy = Taxonomy.bundled
        #expect(taxonomy.search("").count == taxonomy.types.count)
        #expect(!taxonomy.search("lixo").isEmpty)
        #expect(!taxonomy.search("litter").isEmpty)
        #expect(taxonomy.search("zzzzzzzz").isEmpty)
    }

    @Test("areas group the types without losing any")
    func areas() {
        let taxonomy = Taxonomy.bundled
        let grouped = taxonomy.areas.flatMap { taxonomy.types(inArea: $0.id) }
        #expect(grouped.count == taxonomy.types.count)
    }

    /// Find a substring that genuinely hits more than one live type, so the
    /// ambiguity test does not depend on wording that may be reorganised.
    private func ambiguousNeedle() -> String {
        for candidate in ["ecoponto", "manutencao", "reparacao", "limpeza", "recolha"] {
            if Taxonomy.bundled.search(candidate).count > 1 { return candidate }
        }
        return "ecoponto"
    }
}
