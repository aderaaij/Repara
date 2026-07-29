import ReparaCore
import SwiftUI

/// The 127 occurrence types, bundled and searchable in Portuguese and English.
///
/// Grouped by council area, because the area is what disambiguates the several
/// subcategories that share wording — "Manutenção ou reparação" means something
/// different under Habitação Municipal than under Passeios e Acessibilidades,
/// and they route to different desks.
///
/// Presented as a sheet from Review, where picking a type re-prepares the
/// report. `TypeCatalogueView` is the same list without the picking.
struct TypePickerView: View {
    @Binding var selection: TipoOcorrencia?
    var onPick: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TypeList(selection: $selection) {
                onPick()
                dismiss()
            }
            .navigationTitle("Report type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// The same taxonomy, browsable rather than selectable — "what can I even
/// report?", asked away from the middle of filing a report.
///
/// Meant to be pushed onto an existing `NavigationStack`; `.searchable` needs
/// one to render its field.
struct TypeCatalogueView: View {
    var body: some View {
        TypeList(selection: nil)
            .navigationTitle("What you can report")
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - The list itself

/// Shared so the browsable copy cannot drift from the one people file under.
private struct TypeList: View {
    /// `nil` when browsing: rows stop being buttons and nothing is ticked.
    var selection: Binding<TipoOcorrencia?>?
    var onPick: () -> Void = {}

    @State private var query = ""

    private let taxonomy = Taxonomy.bundled

    var body: some View {
        List {
            ForEach(areas, id: \.id) { area in
                Section(header: areaHeader(area)) {
                    ForEach(types(in: area.id)) { type in
                        row(type)
                    }
                }
            }

            if selection == nil && query.isEmpty {
                Section {
                } footer: {
                    Text("\(taxonomy.types.count) types across \(taxonomy.areas.count) council areas, bundled with the app rather than fetched. The area is part of the answer: several types share wording and route to different desks.")
                }
            }
        }
        .searchable(text: $query, prompt: "Search — pothole works as well as buraco")
        .overlay {
            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    @ViewBuilder private func row(_ type: TipoOcorrencia) -> some View {
        if let selection {
            Button {
                selection.wrappedValue = type
                onPick()
            } label: {
                label(type, ticked: selection.wrappedValue?.id == type.id)
            }
            .tint(.primary)
        } else {
            label(type, ticked: false)
        }
    }

    private func label(_ type: TipoOcorrencia, ticked: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(type.descricao)
                if let english = type.en {
                    Text(english)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if ticked {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
    }

    @ViewBuilder private func areaHeader(_ area: AreaOcorrencia) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(area.descricao)
            if let english = taxonomy.types(inArea: area.id).first?.areaEn {
                Text(english).font(.caption2).textCase(nil).foregroundStyle(.tertiary)
            }
        }
    }

    private var matches: [TipoOcorrencia] {
        query.isEmpty ? taxonomy.types : taxonomy.search(query)
    }

    private var areas: [AreaOcorrencia] {
        let present = Set(matches.map(\.areaOcorrenciaId))
        return taxonomy.areas.filter { present.contains($0.id) }
    }

    private func types(in areaId: Int) -> [TipoOcorrencia] {
        matches.filter { $0.areaOcorrenciaId == areaId }
    }
}
