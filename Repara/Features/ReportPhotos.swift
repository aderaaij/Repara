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

    /// Which photograph the viewer was opened on. A position in the strip, so
    /// the sheet and the thumbnail cannot disagree about which one was tapped.
    @State private var opened: Opened?

    private struct Opened: Identifiable {
        let id: Int
    }

    var body: some View {
        content
            .task { await load() }
            .fullScreenCover(item: $opened) { opened in
                if case let .loaded(images) = state {
                    PhotoViewer(
                        photos: images.compactMap { UIImage(data: $0) }, index: opened.id)
                }
            }
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
            // Decoded here rather than held decoded in `state`, so that "the
            // portal listed no photograph" stays a fact about the answer and not
            // about whether the bytes turned out to be readable.
            strip(images.compactMap { UIImage(data: $0) })

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

    // MARK: The strip

    /// The photographs, each at its own shape and each a way into `PhotoViewer`.
    ///
    /// **The height is fixed and the width follows the photograph**, rather than
    /// both being fixed. A 240×180 window with `scaledToFill` behind it is a
    /// centre crop, and a phone photograph is portrait far more often than not —
    /// so nearly every one of these was being shown as a landscape band cut out
    /// of the middle of a portrait shot, which is the part of a fly-tipping
    /// photograph least likely to contain the fly-tipping.
    ///
    /// The clamp is there for the panorama and the receipt-shaped screenshot.
    /// It is set wide enough that **nothing a phone takes is cropped**: 9:16
    /// portrait lands on 101, 3:4 on 135, square on 180, 4:3 on 240 and 16:9 on
    /// 320, and all five are inside it.
    private func strip(_ photos: [UIImage]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(photos.enumerated()), id: \.offset) { position, image in
                    Button {
                        opened = Opened(id: position)
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: Self.width(for: image), height: Self.stripHeight)
                            .clipShape(
                                .rect(cornerRadius: Repara.Radius.card, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Photo \(position + 1) of \(photos.count)"))
                    .accessibilityHint(Text("Opens it full screen."))
                }
            }
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.hidden)
        .frame(height: Self.stripHeight)
    }

    private static let stripHeight: CGFloat = 180

    /// `UIImage.size` is orientation-corrected — a portrait photograph carrying
    /// an EXIF rotation reports itself as portrait — so this is the shape the
    /// photograph will actually be drawn at.
    private static func width(for image: UIImage) -> CGFloat {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return stripHeight }
        return min(max(stripHeight * (size.width / size.height), 100), 320)
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
