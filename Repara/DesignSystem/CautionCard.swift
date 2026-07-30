import SwiftUI

/// The four things this app can have to say before a report is filed, named by
/// **the action each one wants** rather than by severity.
///
/// A severity ladder was the obvious scheme and it fails on the one that
/// matters: "we could not find out" is not *less severe* than a duplicate, it
/// is a different kind of claim, and a ladder files it under Context next to
/// things that are fine. Naming the action is also what makes each card
/// answerable — the user knows what to do without reading a paragraph.
///
/// Each tier gets a **shape signature** as well as a hue, because colour alone
/// cannot carry this: two of the cautions the app showed before this were both
/// orange and meant opposite things. Print the four in black and white —
/// keyline, dashes, hatch and a bare inline row are still four different
/// objects. That is the bar, because the real viewing condition is a phone at
/// 40% brightness in direct sun.
enum CautionTier {
    /// Something is already booked here. Filing sends a second worker to a job
    /// that is on somebody's list. The only filled surface in the set.
    case stop
    /// A nearby report might be this same problem. Wants an answer, not an
    /// acknowledgement.
    case decide
    /// A lookup is still running. Named rather than silent, because a warning
    /// that appears a second after the screen does reads as the app changing
    /// its mind — and dashed rather than hatched, because "still asking" and
    /// "asked and got nothing back" are different claims.
    case pending
    /// The council's server did not answer. **Never green and never a tick** —
    /// "not checked" and "checked, nothing here" are the two states this app
    /// most has to keep apart.
    case unverified
    /// Worth fixing if you can, not worth a card. No surface at all.
    case headsUp

    var tint: Color {
        switch self {
        case .stop: Repara.stop
        case .decide: Repara.amber
        case .pending, .unverified: Repara.unknown
        case .headsUp: Repara.headsUp
        }
    }

    /// The tint, in the shade that is readable as text.
    var ink: Color {
        switch self {
        case .stop: Repara.onStop
        case .decide: Repara.amberInk
        case .pending, .unverified: Repara.unknownInk
        case .headsUp: Repara.headsUpInk
        }
    }
}

/// One switch, four looks. Nothing else in the app picks a warning colour.
struct CautionCard<Content: View>: View {
    let tier: CautionTier
    let title: String
    let message: String
    var systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        switch tier {
        case .stop: filled
        case .decide: railed(rail: AnyView(tier.tint))
        case .pending: railed(rail: AnyView(DashedRail(color: tier.tint.opacity(0.5))))
        case .unverified: railed(rail: AnyView(hatchRail), railWidth: 18)
        case .headsUp: inline
        }
    }

    // MARK: Filled — the only one that takes the whole surface

    private var filled: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title).font(.headline)
            } icon: {
                Image(systemName: systemImage)
            }
            .foregroundStyle(tier.ink)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(tier.ink.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tier.tint, in: .rect(cornerRadius: Repara.Radius.card, style: .continuous))
        .shadow(color: tier.tint.opacity(0.22), radius: 9, y: 4)
    }

    // MARK: Railed — a card with a signature stripe down its leading edge

    private func railed(rail: AnyView, railWidth: CGFloat = 5) -> some View {
        HStack(spacing: 0) {
            // `.clipped()` is load-bearing, not tidiness. A `Shape` is not
            // bounded by its frame, and `Hatch` runs each stripe `rect.height`
            // across — in an 18 pt rail 430 pt tall that is a 430 pt stripe,
            // which paints diagonal grey over the card's own text and makes the
            // one caution that must be readable unreadable.
            rail.frame(width: railWidth).clipped()
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(title).font(.headline)
                } icon: {
                    Image(systemName: systemImage)
                }
                .foregroundStyle(tier.ink)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Repara.card)
        .clipShape(.rect(cornerRadius: Repara.Radius.card, style: .continuous))
    }

    private var hatchRail: some View {
        ZStack {
            Repara.card
            Hatch().fill(tier.tint.opacity(0.85))
        }
    }

    // MARK: Inline — deliberately not a card

    private var inline: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .foregroundStyle(tier.tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tier.ink)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension CautionCard where Content == EmptyView {
    init(_ tier: CautionTier, title: String, message: String, systemImage: String) {
        self.init(tier: tier, title: title, message: message, systemImage: systemImage) {
            EmptyView()
        }
    }
}

extension CautionCard {
    init(
        _ tier: CautionTier,
        title: String,
        message: String,
        systemImage: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(tier: tier, title: title, message: message, systemImage: systemImage, content: content)
    }
}

// MARK: - Pieces the tiers share

/// A report quoted inside a caution — the thing the card is asking about.
///
/// Its occurrence number, text and distance and nothing else. What the portal
/// sends alongside those is never decoded; see `NearByOccurrence`.
struct QuotedReport: View {
    var numero: String? = nil
    var tipo: String? = nil
    var text: String? = nil
    var footnote: String
    /// On a filled surface the quote sits in a translucent well; on a white
    /// card it sits in a grey one.
    var onFilledSurface = false
    /// Opens the report in full. When set, the quote becomes a control and says
    /// so — see the note below.
    var onOpen: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if let numero, !numero.isEmpty {
                    Text(numero).font(.footnote.monospaced())
                }
                if let tipo, !tipo.isEmpty {
                    Text(tipo).font(.footnote.monospaced())
                }
                if let text, !text.isEmpty {
                    Text(text).font(.subheadline)
                }
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(onFilledSurface ? .white.opacity(0.85) : Color.secondary)

                // Stated, not merely implied by the chevron. A warning that
                // tells somebody not to file is asking them to trust a claim
                // about a report they cannot see; the way out of that is to say
                // plainly that they can look, not to hide it behind an
                // affordance they have to notice.
                if onOpen != nil {
                    Text("Tap to compare with yours")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(
                            onFilledSurface
                                ? AnyShapeStyle(Repara.onStop) : AnyShapeStyle(Repara.ink)
                        )
                        .padding(.top, 3)
                }
            }

            if onOpen != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        onFilledSurface
                            ? AnyShapeStyle(Color.white.opacity(0.7))
                            : AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                    )
                    .padding(.top, 2)
            }
        }
        .foregroundStyle(
            onFilledSurface ? AnyShapeStyle(Repara.onStop) : AnyShapeStyle(Color.primary))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(
            onFilledSurface
                ? AnyShapeStyle(Color.white.opacity(0.16))
                : AnyShapeStyle(HierarchicalShapeStyle.quaternary),
            in: .rect(cornerRadius: 14, style: .continuous)
        )
        .contentShape(.rect)
        .onTapGesture { onOpen?() }
        .accessibilityAddTraits(onOpen != nil ? .isButton : [])
    }
}

/// The answer chips a Decide or Stop card ends with. Sized so a thumb can hit
/// either without looking, and always in pairs — a single chip is an
/// acknowledgement, which is the thing these cards exist not to be.
struct AnswerChip: View {
    let title: String
    var fill: AnyShapeStyle
    var label: Color
    var stroke: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(label)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(fill, in: .capsule)
                .overlay {
                    if let stroke { Capsule().strokeBorder(stroke, lineWidth: 0.5) }
                }
        }
        .buttonStyle(.plain)
    }

    /// Tinted in the tier's own colour: the answer that agrees with the card.
    static func agreeing(_ title: String, _ tier: CautionTier, action: @escaping () -> Void)
        -> AnswerChip
    {
        switch tier {
        case .stop:
            // On the filled red surface, the agreeing answer is the white one.
            AnswerChip(
                title: title, fill: AnyShapeStyle(Color.white), label: Repara.stop, stroke: nil,
                action: action)
        default:
            AnswerChip(
                title: title, fill: AnyShapeStyle(tier.tint.opacity(0.12)), label: tier.ink,
                stroke: tier.tint.opacity(0.28), action: action)
        }
    }

    /// Neutral: the answer that says the card has the wrong idea.
    static func dissenting(_ title: String, _ tier: CautionTier, action: @escaping () -> Void)
        -> AnswerChip
    {
        switch tier {
        case .stop:
            AnswerChip(
                title: title, fill: AnyShapeStyle(Color.white.opacity(0.18)),
                label: Repara.onStop, stroke: .white.opacity(0.5), action: action)
        default:
            AnswerChip(
                title: title, fill: AnyShapeStyle(HierarchicalShapeStyle.quaternary),
                label: .primary, stroke: nil, action: action)
        }
    }
}

/// The one place a green tick is allowed next to a check: an answer the user
/// actually gave. Never a lookup that failed, and never an empty result.
struct AnsweredNote: View {
    let text: String

    var body: some View {
        Label {
            Text(text).font(.subheadline.weight(.medium))
        } icon: {
            Image(systemName: "checkmark")
        }
        .foregroundStyle(Repara.done)
    }
}
