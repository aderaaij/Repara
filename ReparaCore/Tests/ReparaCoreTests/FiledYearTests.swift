import Foundation
import Testing

@testable import ReparaCore

/// The only thing in a nearby report that says *when*.
///
/// The portal sends no date field at all, so the year is read off the end of the
/// occurrence number. That makes it an inference from a format rather than a
/// fact the server stated, and these pin the two halves of living with that: it
/// reads the shape the portal actually uses, and it says nothing at all rather
/// than something wrong when the shape is not there.
@Suite("Filed year")
struct FiledYearTests {

    private func occurrence(numero: String) throws -> NearByOccurrence {
        try JSONDecoder().decode(
            NearByOccurrence.self,
            from: Data(#"{"id": 1, "numero": "\#(numero)"}"#.utf8))
    }

    @Test("the year is the last segment of the occurrence number")
    func readsTheYear() throws {
        #expect(try occurrence(numero: "OCO/12345/2025").filedYear == 2025)
        #expect(try occurrence(numero: "OCO/7/2021").filedYear == 2021)
    }

    /// Every shape the verified capture contained: the serial runs from three
    /// digits to six, and the year is always the last of three segments.
    @Test("every serial width in the capture reads the same way")
    func serialWidths() throws {
        for serial in ["123", "1234", "12345", "123456"] {
            #expect(try occurrence(numero: "OCO/\(serial)/2026").filedYear == 2026)
        }
    }

    @Test("anything that is not a plausible year reads as no year at all")
    func refusesToGuess() throws {
        #expect(try occurrence(numero: "").filedYear == nil)
        #expect(try occurrence(numero: "OCO/12345").filedYear == nil)
        #expect(try occurrence(numero: "OCO/12345/XX").filedYear == nil)
        #expect(try occurrence(numero: "OCO/12345/1899").filedYear == nil)
        #expect(try occurrence(numero: "12345").filedYear == nil)
    }

    @Test("the span is the earliest and latest years present")
    func span() throws {
        let found = try ["OCO/1/2023", "OCO/2/2021", "OCO/3/2026"].map { try occurrence(numero: $0) }

        #expect(found.filedYears == 2021...2026)
        #expect(found.filed(in: 2021) == 1)
        #expect(found.filed(in: 2024) == 0)
    }

    @Test("a list whose numbers carry no year has no span")
    func noSpan() throws {
        #expect(try [occurrence(numero: "OCO/1")].filedYears == nil)
        #expect([NearByOccurrence]().filedYears == nil)
    }

    /// A list where only some numbers parse still answers, over the ones that
    /// did. Half an answer about when beats none, as long as the count that goes
    /// with it is the count of what was actually read.
    @Test("a mixed list spans only what could be read")
    func partial() throws {
        let found = try ["OCO/1/2024", "malformed"].map { try occurrence(numero: $0) }

        #expect(found.filedYears == 2024...2024)
        #expect(found.filed(in: 2024) == 1)
    }
}
