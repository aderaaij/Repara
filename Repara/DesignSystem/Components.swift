import SwiftUI
import UIKit

// MARK: - Buttons

/// The primary action, in ink. One per screen.
///
/// Ink rather than the terracotta this app used to tint with: a reporting tool
/// that looks like a lifestyle app is a reporting tool people trust with less.
/// It goes red only where the consequence is irreversible — the live submit —
/// and that is the only place red appears on a control.
struct InkButtonStyle: ButtonStyle {
    var tint: Color = Repara.ink
    /// The label colour, passed rather than derived from `tint`: on the live
    /// submit the fill is `Repara.stop`, and white-on-`#FF453A` is the one
    /// combination in this palette that fails in the dark. `Repara.onStop`
    /// flips there and `Repara.onInk` does not.
    var onTint: Color = Repara.onInk
    var height: CGFloat = 56

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(onTint)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(tint, in: .capsule)
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
            }
            .shadow(color: tint.opacity(0.28), radius: 10, y: 5)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(duration: 0.22), value: configuration.isPressed)
    }
}

/// The secondary action: glass over whatever is behind it, ink label.
struct GlassButtonStyle: ButtonStyle {
    var height: CGFloat = 56

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Repara.ink)
            .frame(maxWidth: .infinity, minHeight: height)
            .glassEffect(.regular.interactive(), in: .capsule)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Chips

/// A council status, quoted verbatim.
///
/// `Em curso` / `Concluído` / `Resolvido` are the portal's own words.
/// Translating a council status would be inventing one, and the word on the
/// report is what somebody quotes down the phone. **The colour is presentation
/// over that word, never a substitute for it** — a status this app has not seen
/// before still renders, still reads correctly, and just gets the neutral tone.
struct StatusChip: View {
    let text: String
    let tone: Tone

    /// Why the same "closed" status is green in one place and grey in another.
    ///
    /// On your own reports, closed means the council did the thing, which is
    /// genuinely done. On somebody else's, closed must never read as an
    /// argument against filing — if the problem is back in the street, a
    /// finished report is a reason *to* file — so there it is context, in grey.
    enum Tone {
        case open
        case done
        case context
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(label)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(fill, in: .capsule)
    }

    private var label: Color {
        switch tone {
        case .open: Repara.amberInk
        case .done: Repara.done
        case .context: .secondary
        }
    }

    private var fill: AnyShapeStyle {
        switch tone {
        case .open: AnyShapeStyle(Repara.amber.opacity(0.22))
        case .done: AnyShapeStyle(Repara.done.opacity(0.16))
        case .context: AnyShapeStyle(.quaternary)
        }
    }
}

// MARK: - Distances

/// "8 m away", or "nearby" when the distance was never filled in.
///
/// **The only way this app formats a distance.** `NearByOccurrence.distance`
/// starts as `.nan` and is filled in by `stripped(relativeTo:)`, and
/// `Int(Double.nan)` *traps* — so a report that reached a view without going
/// through that would crash the screen rather than read a little vaguely.
///
/// Takes the locale rather than reading the current one, because this is called
/// from view bodies that already have the app's chosen language in the
/// environment, and the two must not be able to disagree.
func distancePhrase(_ distance: Double, in locale: Locale) -> String {
    guard distance.isFinite else {
        return String(localized: "nearby", bundle: locale.bundle, locale: locale)
    }
    return String(
        localized: "\(Int(distance.rounded())) m away", bundle: locale.bundle, locale: locale)
}

/// "8 m", or nil when the distance was never filled in, so a caller composing a
/// sentence around it can choose different words rather than say "nearby from
/// your pin".
///
/// Not localised, and does not need to be: it is a number and the SI symbol for
/// it, which read the same in both languages, and every distance this app shows
/// is under a kilometre so no separator is involved.
func metres(_ distance: Double) -> String? {
    distance.isFinite ? "\(Int(distance.rounded())) m" : nil
}

/// Whether a council status word reads as still open.
///
/// A guess over the portal's vocabulary, used only to pick a chip colour and a
/// keyline. The status itself is always shown verbatim beside it, so a word this
/// does not recognise costs a shade of grey and misinforms nobody.
func statusReadsAsOpen(_ estado: String) -> Bool {
    let closed = ["conclu", "resolvid", "encerrad", "anulad", "cancelad"]
    let lower = estado.lowercased()
    return !closed.contains { lower.contains($0) }
}

/// A floating glass control over a map or a camera frame.
struct GlassChip<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .frame(height: 38)
            .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Rows

/// A one-line summary that expands in place.
///
/// The map, the type and the photo are all confirmation rather than controls by
/// the time Review is on screen — the pin was placed on the previous step — so
/// they collapse to a line each and open when questioned. The 240 pt map that
/// used to open this screen pushed the Portuguese text, which is the thing that
/// actually gets sent, below the fold.
/// `Text` rather than `String` for the two labels — see `PushRow`, which took
/// the same change for the same reason.
struct DisclosureRow<Detail: View>: View {
    let systemImage: String
    let title: Text
    let subtitle: Text
    @Binding var isExpanded: Bool
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.28)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        title
                            .font(.body)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        subtitle
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded { detail() }
        }
    }
}

/// A row that pushes somewhere, rather than opening in place.
///
/// The labels are `Text`, not `String`, and that is a localisation decision
/// rather than a stylistic one. `Text(someString)` is the *verbatim* overload,
/// so a row taking `String` silently swallowed every literal handed to it — "1
/// photo attached" and "All types" were never extracted into the catalogue and
/// would have stayed English in a Portuguese app, with nothing to notice.
/// Taking `Text` puts the choice at the call site, where one caller passes copy
/// to translate and the next passes a council type name that must not be.
struct PushRow: View {
    let systemImage: String
    let title: Text
    let subtitle: Text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    title
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    subtitle
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Layout helpers

/// The grouped-card surface every list-like block on the redesigned screens
/// sits on.
struct CardGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(Repara.card)
            .clipShape(.rect(cornerRadius: Repara.Radius.card, style: .continuous))
    }
}

/// One labelled value from the council's record — "Freguesia · Santa Maria
/// Maior".
///
/// **The two halves take different types on purpose, and it is a localisation
/// rule rather than a stylistic one.** The name is always this app's copy, so it
/// is a `LocalizedStringKey` and translates; the value is always something the
/// portal said, so it is a `String` and takes `Text`'s verbatim overload. A
/// single `String` for both would have quietly shipped every label in English.
///
/// Shared by `OccurrenceSheet` and `MyReportDetailView`, which print the same
/// kinds of fact about somebody else's report and your own.
struct FactRow: View {
    let name: LocalizedStringKey
    let value: String

    init(_ name: LocalizedStringKey, _ value: String) {
        self.name = name
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Repara.hairline)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}

extension View {
    /// A section title in the redesigned scale — 20/25 semibold, above a card
    /// rather than inside a `Form` header.
    func reparaSectionTitle() -> some View {
        font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }

    /// The quiet explanatory line under a card. Footers on the old screens ran
    /// to paragraphs; these are one sentence and say something the card cannot.
    func reparaFootnote() -> some View {
        font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}
