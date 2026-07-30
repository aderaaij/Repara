import Foundation
import Testing

@testable import ReparaCore

/// The app is bilingual. **The report is not.**
///
/// `descricao` is filed in European Portuguese whatever language the app is set
/// to, because a council worker reads it and acts on it. That is the one thing
/// localisation must never reach, and these tests are here so that a later
/// "translate everything" pass cannot quietly reach it — the submission path
/// takes no locale, and nothing on the way to the payload consults one.
///
/// The rest is the reverse: the things that *should* follow the reader.
@Suite("Language")
struct LanguageTests {

    private static let english = Locale(identifier: "en_GB")
    private static let portuguese = Locale(identifier: "pt_PT")

    // MARK: What is filed

    @Test("the filed description is the text handed in, byte for byte")
    func filedBodyIsVerbatim() async throws {
        let (client, _) = try Fixture.client(returning: "geo-attributes-building")
        let body = "Sacos de lixo abandonados no passeio."

        let report = try await Submitter(client: client).prepare(
            type: .litter, at: Projection.reference.wgs84, descricao: body)

        #expect(report.obj.descricao == body)
    }

    /// The blunt version, in the spirit of `PrivacyTests`: the English gloss
    /// exists on this type, and it must appear **nowhere** in what gets posted.
    ///
    /// A subtler assertion is one somebody can satisfy without meaning it.
    @Test("no English reaches the payload, even for a type that has a translation")
    func payloadCarriesNoTranslation() async throws {
        let (client, _) = try Fixture.client(returning: "geo-attributes-building")
        let type = TipoOcorrencia.litter
        #expect(type.en != nil, "this test is pointless if the fixture has no gloss")

        let report = try await Submitter(client: client).prepare(
            type: type, at: Projection.reference.wgs84,
            descricao: "Sacos de lixo abandonados no passeio.")
        let payload = String(decoding: try report.obj.encoded(), as: UTF8.self)

        #expect(!payload.contains(try #require(type.en)))
        #expect(!payload.contains(try #require(type.areaEn)))
        // What routes the report is the council's own id, not either name.
        #expect(report.obj.tipoOcorrenciaId == type.id)
    }

    // MARK: Which language a reader wants

    /// A phone set to Brazilian Portuguese must not fall past `pt-PT` and land
    /// on English — Lisbon has a great many Brazilian residents, and the app
    /// only ships the European wording.
    @Test("any Portuguese counts as Portuguese")
    func portugueseVariants() {
        for identifier in ["pt_PT", "pt_BR", "pt", "pt_AO", "pt_MZ"] {
            #expect(Locale(identifier: identifier).prefersPortuguese, "\(identifier)")
        }
        for identifier in ["en_GB", "en_US", "nl_NL", "fr_FR", "es_ES"] {
            #expect(!Locale(identifier: identifier).prefersPortuguese, "\(identifier)")
        }
    }

    // MARK: Type names

    @Test("a reader gets the name in their own language")
    func namesFollowTheReader() {
        let type = TipoOcorrencia.litter
        #expect(type.localizedDescricao(in: Self.portuguese) == type.descricao)
        #expect(type.localizedDescricao(in: Self.english) == type.en)
        #expect(type.localizedArea(in: Self.portuguese) == type.area)
        #expect(type.localizedArea(in: Self.english) == type.areaEn)
    }

    /// Portuguese is the fallback, not the alternative: `en` is hand-written and
    /// may be absent, so an unglossed type shows the name the council itself
    /// uses rather than an empty row.
    @Test("an untranslated type shows the council's own name")
    func fallsBackToTheCouncilsWording() {
        let unglossed = TipoOcorrencia(
            id: 1, areaOcorrenciaId: 2, area: "Higiene Urbana",
            descricao: "Um tipo sem tradução", slug: "um-tipo-sem-traducao")

        #expect(unglossed.localizedDescricao(in: Self.english) == "Um tipo sem tradução")
        #expect(unglossed.localizedArea(in: Self.english) == "Higiene Urbana")
        #expect(unglossed.englishGloss(in: Self.english) == nil)
        #expect(unglossed.alternateDescricao(in: Self.english) == nil)
    }

    /// One name in a Portuguese app. Printing an English translation under every
    /// row would be noise on a screen already asking the reader to tell 127
    /// similar things apart.
    @Test("no second name in a Portuguese app")
    func noSecondNameInPortuguese() {
        let type = TipoOcorrencia.litter
        #expect(type.englishGloss(in: Self.portuguese) == nil)
        #expect(type.alternateDescricao(in: Self.portuguese) == nil)
        #expect(type.alternateArea(in: Self.portuguese) == nil)
    }

    /// The two screens pair the names in opposite orders on purpose: Review
    /// keeps the council's wording as the headline because it is the screen that
    /// says *this is what is being sent*, while browsing leads with the language
    /// the reader can actually read.
    @Test("both names available in an English app, and they are the two different ones")
    func bothNamesInEnglish() {
        let type = TipoOcorrencia.litter
        #expect(type.englishGloss(in: Self.english) == type.en)
        #expect(type.alternateDescricao(in: Self.english) == type.descricao)
        #expect(type.englishGloss(in: Self.english) != type.alternateDescricao(in: Self.english))
    }

    // MARK: This package's own messages

    /// Also proves the `.lproj` is wired up at all: SwiftPM copies an
    /// `.xcstrings` into the bundle **without compiling it**, so a string
    /// catalogue here would have silently resolved to English for ever.
    @Test("the errors that ask for an action are translated")
    func actionableErrorsTranslate() {
        let portuguese = PortalError.loginFailed.message(in: Self.portuguese)
        let english = PortalError.loginFailed.message(in: Self.english)

        #expect(portuguese != english)
        #expect(portuguese.contains("sessão"))
        #expect(english.contains("Sign-in failed"))

        #expect(SubmitError.emptyDescription.message(in: Self.portuguese).contains("Descreva"))
        #expect(ProjectionError.outsideLisbon(Projection.reference.ptTm06)
            .message(in: Self.portuguese).contains("fora do município"))
    }

    /// A status code, a path and a content type are for pasting into a bug
    /// report. Translating them helps nobody, so they stay as `description`.
    @Test("diagnostics are not translated")
    func diagnosticsStayEnglish() {
        let http = PortalError.http(status: 500, path: "/ocorrencias", body: "boom")
        #expect(http.message(in: Self.portuguese) == http.description)

        let drift = ProjectionError.selfCheckFailed(
            driftMetres: 114, expected: Projection.reference.ptTm06,
            got: Projection.reference.ptTm06)
        #expect(drift.message(in: Self.portuguese) == drift.description)
    }
}
