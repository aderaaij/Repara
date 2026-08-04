import ReparaCore
import SwiftUI

/// One of your own reports, in full — pushed from a row on `StatusView`.
///
/// The list clips the description at three lines and shows a number, a status
/// and a type. That is the right amount to scan twenty rows with and not enough
/// to answer "which one was this, and what has happened to it", which is the
/// question somebody opens their own report to ask.
///
/// **It costs one request, and only the photographs.** Everything else on this
/// screen arrived with the list: `/ocorrencias/my` sends the department, the
/// freguesia, the address, whoever it is assigned to and the filing date on
/// every row, and until now all of it was decoded and thrown away. The
/// photographs are the one thing that is not in that answer, and they are
/// fetched on opening rather than for a list — see `ReportPhotos`.
///
/// **Nothing editorialises the status.** "Marked done by the council. If the
/// problem is back, file it again" is a true and useful sentence and it belongs
/// on `OccurrenceSheet`, where somebody is reading a *stranger's* finished
/// report and could conclude the street is handled. On your own report the
/// council's word is the whole message, so it is quoted and left alone.
///
/// The rows that are absent are absent rather than blank. Nobody has seen this
/// endpoint's response body — the captured session only ever called the path
/// that 404s — so every field beyond the five the list already used is optional
/// by construction, and a screen missing three rows is honest where three empty
/// ones would look broken.
struct MyReportDetailView: View {
    let report: MyOccurrence

    private var isOpen: Bool { statusReadsAsOpen(report.estado) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                ReportPhotos(occurrence: report.id)
                if let text = description { descriptionCard(text) }
                facts
                footnote
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Repara.canvas)
        // Verbatim, and meant to be: the occurrence number is the handle you
        // quote down the phone to the council, not copy.
        .navigationTitle(report.numero)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Header

    /// The council's own status word and the type it was filed under.
    ///
    /// Green when closed, unlike Browse: on your own report closed means the
    /// council did the thing. `StatusChip.Tone` carries that distinction and the
    /// reason for it.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StatusChip(text: report.estado, tone: isOpen ? .open : .done)
                Spacer(minLength: 8)
                if let filed = filedPhrase {
                    Text(filed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // The council's own words for the type, quoted. There is no English
            // gloss here even in English, for the reason the 127 type names are
            // data and not copy: this screen shows the record the council holds,
            // and the name on it is the one that routed the report to a desk.
            if !report.tipo.isEmpty {
                Text(report.tipo)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    /// "Filed 12-03-2026", or "Filed 2026" off the report number when the
    /// portal sent no date, or nothing at all when it sent neither.
    ///
    /// A whole sentence per branch rather than "Filed " plus a value, so a
    /// translator can move the word.
    private var filedPhrase: LocalizedStringKey? {
        if let date = report.dataCriacao?.trimmingCharacters(in: .whitespacesAndNewlines),
            !date.isEmpty
        {
            return "Filed \(date)"
        }
        // `String(year)`, not the integer: a year interpolated as a number takes
        // a grouping separator, and pt-PT prints 2026 as "2 026".
        if let year = report.filedYear { return "Filed \(String(year))" }
        return nil
    }

    // MARK: Description

    private var description: String? {
        let text = report.descricao?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// In full and selectable, which is half the reason this screen exists: the
    /// row it was opened from clips at three lines.
    ///
    /// "What you reported", not "what was reported" — this is the Portuguese
    /// that was filed under your account and that a council worker read.
    private func descriptionCard(_ text: String) -> some View {
        CardGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text("What you reported")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    // MARK: Facts

    /// The address leads, because it is what tells two of your own reports
    /// apart. `OccurrenceSheet` shows a map and no address for the opposite
    /// reason — there, the address belongs to a household that is not the
    /// reader's. See `MyOccurrence.local`.
    private var facts: some View {
        CardGroup {
            VStack(spacing: 0) {
                ForEach(Array(factRows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { RowDivider() }
                    FactRow(row.name, row.value)
                }
            }
        }
    }

    /// Built as a list rather than as a run of `if`s with a `RowDivider()`
    /// wedged between them, because which rows arrive is genuinely unknown here
    /// and hand-placed dividers get it wrong the first time a field goes
    /// missing — a hairline above nothing, or two rows fused together.
    private struct Fact {
        let name: LocalizedStringKey
        let value: String
    }

    private var factRows: [Fact] {
        var rows: [Fact] = []
        if let address = trimmed(report.local) { rows.append(Fact(name: "Address", value: address)) }
        if !report.freguesia.isEmpty {
            rows.append(Fact(name: "Freguesia", value: report.freguesia))
        }
        if !report.area.isEmpty { rows.append(Fact(name: "Department", value: report.area)) }
        if let responsavel = trimmed(report.responsavel) {
            rows.append(Fact(name: "Handled by", value: responsavel))
        }
        // Always last and always present: the number is the one thing every
        // shape of this answer carries, so the card is never empty.
        rows.append(Fact(name: "Occurrence", value: report.numero))
        return rows
    }

    private func trimmed(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    // MARK: Footnote

    /// One, and it names a real gap rather than restating the screen.
    ///
    /// The council's own portal carries a comment thread on each report — where
    /// it asks for more information, and where a closed report can be asked to
    /// be reopened — and Repara does not read it. Without saying so, a screen
    /// titled with your occurrence number reads as everything the council has
    /// said, and silence reads as "they have said nothing".
    private var footnote: some View {
        Text(
            """
            The council can add comments to a report and reopen a closed one. Repara does not \
            read those yet — naminharualx.cm-lisboa.pt does.
            """
        )
        .reparaFootnote()
        .padding(.top, 2)
    }
}
