import ReparaCore
import SwiftUI

/// The council's photographs of one report, fetched when the screen carrying
/// them appears and never before.
///
/// One report opened is one request, and a list of eighty-nine would otherwise
/// be eighty-nine — so this is deliberately a view that loads its own data on
/// appearance rather than something a list can prefetch.
///
/// Shared by `OccurrenceSheet`, which shows a stranger's report, and
/// `MyReportDetailView`, which shows your own. The request, the cap and the
/// four states are identical in both cases, and the two copies had already begun
/// to be a place where "no photograph on this report" could come to mean
/// different things on two screens.
///
/// The four states are kept apart for the reason every other check in this app
/// keeps them apart — "no photograph on this report" and "we could not ask" are
/// different facts, and the second must not render as the first.
struct ReportPhotos: View {
    /// The occurrence id, not the report: both callers hold different types that
    /// happen to describe the same thing, and an id is all this needs.
    let occurrence: Int

    @Environment(AppModel.self) private var model

    /// Starts loading rather than idle, and that is load-bearing rather than
    /// tidy. `.task` has to attach to a view that actually renders — a
    /// `@ViewBuilder` whose live branch is `EmptyView` drops its modifiers, so an
    /// idle first state meant the fetch never started and every report showed
    /// nothing at all where its photographs should be. There is also no such
    /// thing as idle here: this view existing *is* the request.
    @State private var state = Load.loading

    /// Separate from `state`, because `.loading` is now the starting value and
    /// so cannot double as "a request is already in flight".
    @State private var isFetching = false

    enum Load {
        case loading
        case loaded([Data])
        case failed(String)
    }

    var body: some View {
        content.task { await load() }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Looking for photographs…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)

        case let .loaded(images) where images.isEmpty:
            Text("No photograph on this report.")
                .reparaFootnote()

        case let .loaded(images):
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                        if let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 240, height: 180)
                                .clipShape(
                                    .rect(cornerRadius: Repara.Radius.card, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)
            .frame(height: 180)

        case let .failed(why):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Could not load the photographs — \(why)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Try again") { Task { await load(force: true) } }
                    .font(.footnote.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    /// At most `maxPhotos` images. The portal's own form takes three, so a
    /// report with more than a handful means the shape is not what we think it
    /// is, and downloading all of it would be a lot of somebody's data for a
    /// guess.
    private func load(force: Bool = false) async {
        if case .loaded = state, !force { return }
        if isFetching { return }
        isFetching = true
        defer { isFetching = false }
        state = .loading
        do {
            let urls = try await Photos.urls(model.client, occurrence: occurrence)
            var images: [Data] = []
            for url in urls.prefix(Self.maxPhotos) {
                images.append(try await Photos.image(model.client, at: url))
            }
            state = .loaded(images)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    private static let maxPhotos = 4

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let error as PortalError:
            return error.message(in: AppLanguage.selected.locale)
        default: return error.localizedDescription
        }
    }
}
