import SwiftUI
import UIKit

/// One of a report's photographs, as large as the screen will make it.
///
/// The strip on `ReportPhotos` is a strip: it says how many photographs there
/// are and roughly what they show, at a size where a licence plate, a house
/// number or the actual state of a pavement is unreadable. Deciding whether
/// somebody else's report is *your* problem is exactly the job that needs the
/// pixels, so tapping one opens it here.
///
/// **Nothing is cropped here.** The photograph is fitted whole into the screen,
/// portrait or landscape, and the black around it is the letterbox rather than a
/// background — a photograph is evidence, and a viewer that decides which part
/// of it you get to see is not showing you the evidence.
///
/// Nothing is written to disk and nothing is downloaded: these are the bytes
/// `ReportPhotos` already fetched, held while the sheet is open and forgotten
/// with it, which is the same trade `Photos.image` makes.
struct PhotoViewer: View {
    let photos: [UIImage]

    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(photos: [UIImage], index: Int) {
        self.photos = photos
        _index = State(initialValue: min(max(index, 0), max(photos.count - 1, 0)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.offset) { position, image in
                    ZoomablePhoto(image: image, isCurrent: position == index)
                        .tag(position)
                }
            }
            // No dots. They are three grey pixels over an arbitrary photograph,
            // and this app's viewing condition is a phone at 40% brightness in
            // direct sun — the counter below says the same thing in words that
            // survive it.
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) { chrome }
        .statusBarHidden()
    }

    // MARK: Chrome

    /// Translucent ink with white glyphs, like `CaptureView`'s on-frame
    /// controls and for the same reason: glass adapts to what is behind it, and
    /// what is behind this is somebody's photograph of a sunlit pavement.
    private var chrome: some View {
        HStack(alignment: .center) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.white.opacity(0.16), in: .circle)
                    .overlay { Circle().strokeBorder(.white.opacity(0.32), lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))

            Spacer(minLength: 8)

            // Only with more than one, and it doubles as the only hint that the
            // others are a swipe away.
            if photos.count > 1 {
                Text("Photo \(index + 1) of \(photos.count)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .background(.black.opacity(0.45), in: .capsule)
                    .overlay { Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

/// One photograph, fitted to the screen and zoomable from there.
///
/// Pinch, double-tap and drag, which is what every other photograph on this
/// phone does — a viewer that opens larger but cannot be gone into is only half
/// the answer when the thing to read is a street sign at the back of the shot.
private struct ZoomablePhoto: View {
    let image: UIImage

    /// Whether this is the page on screen. Leaving a page returns it to
    /// fit-to-screen, so swiping back to it does not resume a zoom from before —
    /// arriving at a photograph already magnified into one corner reads as a
    /// broken image rather than as a remembered position.
    let isCurrent: Bool

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    private static let maxScale: CGFloat = 5
    private static let tapScale: CGFloat = 2.5

    var body: some View {
        GeometryReader { proxy in
            let fitted = Self.fit(image.size, in: proxy.size)
            let live = min(max(scale * pinch, 1), Self.maxScale)

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: fitted.width, height: fitted.height)
                .scaleEffect(live)
                .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(.rect)
                .gesture(magnify(fitted: fitted, in: proxy.size))
                // Zoomed in, a drag pans the photograph; fitted, it belongs to
                // the pager so the next photograph is still one swipe away.
                .highPriorityGesture(
                    pan(fitted: fitted, in: proxy.size),
                    including: scale > 1 ? .all : .subviews
                )
                .onTapGesture(count: 2) {
                    withAnimation(.snappy) {
                        if scale > 1 {
                            scale = 1
                            offset = .zero
                        } else {
                            scale = Self.tapScale
                        }
                    }
                }
                .onChange(of: isCurrent) { _, current in
                    if !current {
                        scale = 1
                        offset = .zero
                    }
                }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Photograph on this report"))
    }

    private func magnify(fitted: CGSize, in container: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                let next = min(max(scale * value.magnification, 1), Self.maxScale)
                scale = next
                offset =
                    next <= 1
                    ? .zero : Self.clamp(offset, fitted: fitted, in: container, scale: next)
            }
    }

    private func pan(fitted: CGSize, in container: CGSize) -> some Gesture {
        DragGesture()
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                let proposed = CGSize(
                    width: offset.width + value.translation.width,
                    height: offset.height + value.translation.height
                )
                withAnimation(.snappy) {
                    offset = Self.clamp(proposed, fitted: fitted, in: container, scale: scale)
                }
            }
    }

    /// The photograph at its fitted size, which is the size it is drawn at
    /// before any zoom. `UIImage.size` is already orientation-corrected, so a
    /// portrait shot carrying an EXIF rotation fits as a portrait.
    private static func fit(_ size: CGSize, in container: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, container.width > 0, container.height > 0
        else { return container }
        let ratio = min(container.width / size.width, container.height / size.height)
        return CGSize(width: size.width * ratio, height: size.height * ratio)
    }

    /// Held to the edges of the photograph, so a pan cannot fling it off the
    /// screen and leave black.
    private static func clamp(
        _ proposed: CGSize, fitted: CGSize, in container: CGSize, scale: CGFloat
    ) -> CGSize {
        let slackX = max((fitted.width * scale - container.width) / 2, 0)
        let slackY = max((fitted.height * scale - container.height) / 2, 0)
        return CGSize(
            width: min(max(proposed.width, -slackX), slackX),
            height: min(max(proposed.height, -slackY), slackY)
        )
    }
}
