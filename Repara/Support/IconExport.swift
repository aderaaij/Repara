#if DEBUG

    import ImageIO
    import SwiftUI
    import UIKit
    import UniformTypeIdentifiers

    /// Renders the app icon from `ReparaMark`, so the icon on the home screen and
    /// the mark on the launch screen cannot drift apart. `Tools/appicon.sh` runs
    /// this in the simulator and copies the PNG into the asset catalogue.
    ///
    /// Inert unless `--render-app-icon` is on the command line, and compiled out
    /// of release builds. In every other run it is one `ProcessInfo` read.
    enum IconExport {

        static let isActive = ProcessInfo.processInfo.arguments.contains("--render-app-icon")

        /// 1024 pt at scale 1. The one size the catalogue asks for; Xcode derives
        /// the rest.
        static let side: CGFloat = 1024

        static let filename = "AppIcon-1024.png"

        /// Written to the app's Documents directory, which `simctl
        /// get_app_container … data` can find from outside.
        static var destination: URL {
            URL.documentsDirectory.appending(path: filename)
        }

        /// - Returns: the file written, or `nil` if rendering produced nothing.
        @MainActor
        static func write() -> URL? {
            // Light explicitly: `Repara.amber` is a dynamic colour, and an icon
            // that came out different depending on the simulator's appearance
            // would be a fine way to ship two of them.
            let renderer = ImageRenderer(
                content: ReparaMark(size: side, bleed: true)
                    .environment(\.colorScheme, .light))
            renderer.scale = 1

            guard let rendered = renderer.uiImage?.cgImage else { return nil }

            // Redrawn without an alpha channel — an app icon carrying one is
            // rejected at submission, and every UIKit renderer keeps one whether
            // or not anything in the drawing is transparent. `noneSkipLast` is
            // what makes the PNG come out as RGB rather than RGBA.
            let pixels = Int(side)
            guard
                let context = CGContext(
                    data: nil, width: pixels, height: pixels,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            context.draw(rendered, in: CGRect(x: 0, y: 0, width: side, height: side))

            guard
                let flattened = context.makeImage(),
                let sink = CGImageDestinationCreateWithURL(
                    destination as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(sink, flattened, nil)
            return CGImageDestinationFinalize(sink) ? destination : nil
        }
    }

    /// Holds the screen for as long as it takes to write one PNG. Nothing else in
    /// the app is constructed in this mode — no `AppModel`, no session check.
    struct IconExportHost: View {
        @State private var written: URL?

        var body: some View {
            ZStack {
                Color(red: 0.098, green: 0.110, blue: 0.129).ignoresSafeArea()
                VStack(spacing: 16) {
                    ReparaMark(size: 120)
                    Text(written.map { "Wrote \($0.lastPathComponent)" } ?? "Rendering…")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .task { written = IconExport.write() }
        }
    }

#endif
