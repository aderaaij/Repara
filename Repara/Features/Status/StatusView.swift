import ReparaCore
import SwiftUI

/// `GET /ocorrencias/my` — what you have filed, and where it got to.
///
/// The status comes from the council and is shown in the council's own words.
/// Closed is green here, unlike on the Browse screen: on your own report closed
/// means the council did the thing. On somebody else's it must never read as an
/// argument against filing.
///
/// Which is why this screen does not carry the "a closed report is not proof the
/// problem is gone" footnote it used to. Green above and that sentence below
/// were the same screen disagreeing with itself, and the claim belongs where
/// somebody is reading a *stranger's* finished report — `OccurrenceSheet`.
struct StatusView: View {
    @Environment(AppModel.self) private var model

    @State private var reports: [MyOccurrence] = []
    @State private var isLoading = false
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let failure {
                    CautionCard(
                        .unverified,
                        title: Text("Could not load your reports"),
                        // Verbatim: whatever the portal or the network said,
                        // quoted rather than translated.
                        message: Text(failure),
                        systemImage: "wifi.exclamationmark"
                    )
                }

                if !reports.isEmpty {
                    Text("\(reports.count) filed from this account. Statuses come from the council.")
                        .reparaFootnote()

                    CardGroup {
                        ForEach(Array(reports.enumerated()), id: \.element.id) { index, report in
                            if index > 0 { RowDivider() }
                            row(report)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Repara.canvas)
        .overlay {
            if reports.isEmpty && !isLoading && failure == nil {
                ContentUnavailableView(
                    "Nothing filed yet",
                    systemImage: "tray",
                    description: Text("Reports you file from this account show up here.")
                )
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(_ report: MyOccurrence) -> some View {
        let isOpen = statusReadsAsOpen(report.estado)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(report.numero)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(isOpen ? .primary : .secondary)
                Spacer(minLength: 8)
                StatusChip(text: report.estado, tone: isOpen ? .open : .done)
            }

            if let text = report.descricao?.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            {
                // Dropped to secondary once the council has closed it: still
                // readable, visibly settled.
                Text(text)
                    .font(.callout)
                    .foregroundStyle(isOpen ? .primary : .secondary)
                    .lineLimit(3)
            }

            Text(report.tipo)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func load() async {
        guard model.account != nil else {
            failure = "Sign in to Na Minha Rua LX to see your reports."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            reports = try await model.submitter.myReports()
            failure = nil
        } catch {
            failure = String(describing: error)
        }
    }
}
