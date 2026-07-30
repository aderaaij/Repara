import SwiftUI
import UIKit

/// Ink & tape.
///
/// Four colours with one job each, and the split between two of them is the
/// whole point: **ink is what you can act on, amber is what wants an answer.**
/// Amber is deliberately *not* the brand accent — an accent that also means
/// "caution" makes every caution mean nothing — so it appears on the mark and
/// on cards asking a question, and nowhere else. Every button, chevron and
/// tappable label is ink.
///
/// Surfaces are system colours (`systemGroupedBackground` and friends), which
/// is what makes dark mode free and correct rather than hand-tuned and nearly
/// right.
enum Repara {

    // MARK: Ink — action

    /// The tint. Fills every primary button and colours every tappable label.
    ///
    /// Light in dark mode rather than staying near-black: ink means "this is
    /// the thing to touch", and on a black background the thing to touch is the
    /// bright one. `onInk` is its label colour and flips with it.
    static let ink = adaptive(light: 0x191C21, dark: 0xF5F5F7)
    static let onInk = adaptive(light: 0xFFFFFF, dark: 0x0B0D10)

    // MARK: Amber — attention

    /// The mark, the tape stripe, and the Decide tier's keyline. **Never a
    /// button fill and never text**: 1.9:1 on white.
    static let amber = adaptive(light: 0xF2B01E, dark: 0xFF9F0A)
    /// The readable shade, for anything amber has to say in words.
    static let amberInk = adaptive(light: 0xA85B00, dark: 0xFFB340)

    // MARK: Red — stop

    static let stop = adaptive(light: 0xD70015, dark: 0xFF453A)
    /// Dark in dark mode: the Stop tier is a *filled* surface, and white on
    /// `#FF453A` is the one combination in this palette that fails in the dark.
    static let onStop = adaptive(light: 0xFFFFFF, dark: 0x1A0002)

    // MARK: Green — done

    /// Filed, "nothing was sent", an answered check. **Never a check that
    /// failed** — see `CautionTier.unverified`.
    static let done = adaptive(light: 0x1E7A3C, dark: 0x3FD168)

    // MARK: Grey — unknown

    /// The hatch. Loud enough to be the loudest non-red signature in the set,
    /// because "we could not find out" is not a quiet fact.
    static let unknown = adaptive(light: 0x6B6B76, dark: 0x8E8E98)
    static let unknownInk = adaptive(light: 0x3A3A44, dark: 0xD5D5DE)

    // MARK: Blue — heads-up

    static let headsUp = adaptive(light: 0x3F5AA6, dark: 0x8E9DE8)
    static let headsUpInk = adaptive(light: 0x2E4480, dark: 0xA8B4EE)

    // MARK: Surfaces

    static let canvas = Color(.systemGroupedBackground)
    static let card = Color(.secondarySystemGroupedBackground)
    static let hairline = Color(.separator)

    // MARK: Metrics

    /// Cards, sheets and the submit bar. One radius family, three sizes.
    enum Radius {
        static let card: CGFloat = 20
        static let hero: CGFloat = 24
        static let bar: CGFloat = 30
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
            })
    }
}

extension UIColor {
    fileprivate convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Signature shapes

/// The diagonal hatch that marks *unknown*.
///
/// It carries the meaning on its own: printed in black and white, or seen on a
/// phone at 40% brightness in direct sun, a hatch is still a different object
/// from a solid keyline. That is the bar the tier signatures are held to,
/// because two of the cautions this app shows are orange today and mean
/// opposite things.
///
/// **Clip wherever you use it.** Each stripe runs `rect.height` horizontally, so
/// in a tall narrow rail the path extends far outside the frame — and a `Shape`
/// is not bounded by its frame.
struct Hatch: Shape {
    var spacing: CGFloat = 9
    var thickness: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let reach = rect.width + rect.height
        var x = -rect.height
        while x < reach {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            path.addLine(to: CGPoint(x: x + rect.height + thickness, y: rect.minY))
            path.addLine(to: CGPoint(x: x + thickness, y: rect.maxY))
            path.closeSubpath()
            x += spacing
        }
        return path
    }
}

/// The dashed rail that marks *in progress*. Distinct from `Hatch` on purpose:
/// "still asking" and "asked and got nothing" are different claims and must not
/// share a signature.
struct DashedRail: View {
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: proxy.size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: proxy.size.width / 2, y: proxy.size.height))
            }
            .strokedPath(
                StrokeStyle(lineWidth: proxy.size.width, dash: [6, 6]))
            .foregroundStyle(color)
        }
    }
}

// MARK: - The mark

/// Ink ground, one signal-amber hazard stripe, white.
///
/// The "unofficial client" line is part of the lockup rather than a disclaimer
/// buried in Settings: it is what keeps the app visibly third-party wherever
/// the mark appears. Nothing here touches the council's identity — that is a
/// black-and-white crest and municipal green — and hazard tape says *a thing
/// needs fixing*, which is the whole product.
struct ReparaMark: View {
    var size: CGFloat = 96

    /// Square ground, no corner of its own — the framing the app icon needs,
    /// because iOS applies its own mask and an icon that rounds itself first
    /// ends up with transparent corners inside it. On screen the mark is always
    /// the rounded one; this is the same drawing, framed for the mask.
    var bleed = false

    private var ink: Color { Color(red: 0.098, green: 0.110, blue: 0.129) }
    private var corner: CGFloat { bleed ? 0 : size * 0.23 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(ink)

            // The tape: a solid amber band with the ink stripes cut across it.
            // It overhangs when full-bleed, because it is tilted and a band
            // exactly one frame wide would end in a diagonal notch at each
            // edge. Rounded, the corner curve hides that, so the band keeps the
            // width — and the stripe phase — it has always had.
            ZStack {
                Rectangle().fill(Repara.amber)
                Hatch(spacing: size * 0.115, thickness: size * 0.05)
                    .fill(ink)
            }
            .frame(width: size * (bleed ? 1.3 : 1), height: size * 0.15)
            .rotationEffect(.degrees(-8))
            .offset(y: size * 0.24)

            RoundedRectangle(cornerRadius: size * 0.21, style: .continuous)
                .stroke(.white, lineWidth: size * 0.08)
                .frame(width: size * 0.69, height: size * 0.69)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: size * 0.34, weight: .bold))
                        .foregroundStyle(Repara.amber)
                }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: corner, style: .continuous))
    }
}

/// The wordmark, with the line that says what this is. The amber full stop is
/// the only decorative use of the accent in the app.
struct ReparaLockup: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text("Repara").foregroundStyle(.white)
                Text(".").foregroundStyle(Repara.amber)
            }
            .font(.system(size: 30, weight: .bold, design: .default))
            .kerning(-0.5)

            Text("Unofficial client · Na Minha Rua LX")
                .font(.caption2.weight(.semibold))
                .kerning(0.5)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background {
            ZStack(alignment: .trailing) {
                Color(red: 0.098, green: 0.110, blue: 0.129)
                ZStack {
                    Rectangle().fill(Repara.amber)
                    Hatch(spacing: 13, thickness: 6)
                        .fill(Color(red: 0.098, green: 0.110, blue: 0.129))
                }
                .frame(width: 10)
            }
        }
        .clipShape(.rect(cornerRadius: 16, style: .continuous))
    }
}
