import ReparaCore
import SwiftUI

/// `GET /ocorrencias/my` — what you have filed, and where it got to.
struct StatusView: View {
    @Environment(AppModel.self) private var model

    @State private var reports: [MyOccurrence] = []
    @State private var isLoading = false
    @State private var failure: String?

    var body: some View {
        List {
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(.red)
            }
            ForEach(reports) { report in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(report.numero).font(.subheadline.monospaced())
                        Spacer()
                        Text(report.estado)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: .capsule)
                    }
                    Text(report.tipo).font(.footnote).foregroundStyle(.secondary)
                    if let text = report.descricao, !text.isEmpty {
                        Text(text).font(.footnote).lineLimit(3)
                    }
                }
                .padding(.vertical, 2)
            }
        }
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
