import PhotosUI
import ReparaCore
import SwiftUI

/// Step one, and the only step that happens outdoors with one hand.
///
/// This was a `Form`, which put the photo button at the top of the screen under
/// the navigation bar — the furthest point on the device from a thumb. It is
/// inverted here: the frame takes the top of the screen, every control lives in
/// the bottom third, the shutter is 68 pt with a 68 pt library button beside it,
/// and the note collapses to one optional row so the fast path is photo → draft.
///
/// Location moves into a chip over the frame, so accuracy is legible without
/// spending a row on it.
///
/// **The camera is the system camera** — `UIImagePickerController`, presented
/// full-screen on the shutter; see `CameraPicker`. There is deliberately no live
/// preview: an AVFoundation session of ours would be capture code to get wrong,
/// and focus, exposure, zoom, HDR and the volume-button shutter all come free
/// from the system one. That matters more here than in most apps, because the
/// photograph *is* the evidence a council worker acts on.
///
/// Which is why `frame` has two visibly different states rather than one dark
/// panel throughout — see its own note. A screen that looks like a viewfinder
/// has promised to behave like one, and this one cannot keep that promise.
struct CaptureView: View {
    @Environment(AppModel.self) private var model
    @State private var showingCamera = false
    @State private var noteExpanded = false
    @State private var libraryItem: PhotosPickerItem?
    @FocusState private var editingNote: Bool

    var body: some View {
        VStack(spacing: 0) {
            frame
            controls
        }
        .background(Repara.canvas)
        .ignoresSafeArea(edges: .top)
        // The frame runs to the top edge, so a navigation bar would put ink
        // labels on an ink photograph. Reports and Settings become the two glass
        // buttons over the frame instead — the same two destinations, reachable
        // one-handed rather than at the far corner from a thumb.
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { image in model.accept(image: image) }
                .ignoresSafeArea()
        }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                    let image = UIImage(data: data)
                {
                    model.accept(image: image)
                }
                libraryItem = nil
            }
        }
    }

    // MARK: The frame

    /// The top of the screen, in whichever of its **two honest states** applies.
    ///
    /// It used to be one dark full-bleed panel either way, with a viewfinder
    /// glyph in the middle when there was no photo yet — which signalled a live
    /// camera feed and then opened a modal system camera instead. A screen that
    /// looks like a viewfinder has promised to behave like one.
    ///
    /// So the empty state is now visibly a **placeholder**: the app's own light
    /// canvas, a dashed inert card saying there is no photo yet, and the shutter
    /// below it. Nothing implies a feed, so the shutter handing over to the
    /// system camera is what you would expect. Only once there is a photo does
    /// the frame go dark and full-bleed — at which point it is a photo
    /// container, and cannot pretend to be anything else.
    @ViewBuilder private var frame: some View {
        if let data = model.photo, let image = UIImage(data: data) {
            photoFrame(image)
        } else {
            placeholderFrame
        }
    }

    /// The `GeometryReader` is not decoration. `scaledToFill` reports the
    /// photograph's own enormous ideal size, and that propagates out far enough
    /// that the overlaid controls were laid out against a width wider than the
    /// screen — which pushed the trailing button off the edge. Sizing the image
    /// explicitly to the container stops the ideal size escaping.
    private func photoFrame(_ image: UIImage) -> some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.106, green: 0.118, blue: 0.137)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // A photograph of a sunlit pavement is nearly white, and the controls
        // over it are white. The scrim is what keeps them legible whatever is in
        // the frame — the same thing every camera UI does, for the same reason.
        .overlay(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) { topControls(overPhoto: true) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Light, dashed and inert. It states what is missing; the buttons below are
    /// the only things on this screen that do anything.
    private var placeholderFrame: some View {
        ZStack(alignment: .top) {
            Repara.canvas

            VStack(spacing: 13) {
                Image(systemName: "camera")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No photo yet")
                    .font(.title3.weight(.semibold))
                Text(
                    "The council gets the full-resolution original — that is the evidence a "
                        + "worker acts on. You place the pin exactly on the next screen."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(26)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])
                    )
            }
            .padding(.horizontal, 20)
            .frame(maxHeight: .infinity)

            topControls(overPhoto: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Chrome

    /// Reports · where you are · Settings.
    ///
    /// Same three controls in the same places in both states, so nothing jumps
    /// when a photo arrives — but styled for what is behind them. Over the
    /// canvas they are real glass with ink glyphs; over a photograph they are
    /// translucent ink with white ones, because glass adapts to what is behind
    /// it and a bright pavement would leave white labels on light glass.
    private func topControls(overPhoto: Bool) -> some View {
        HStack(alignment: .center) {
            NavigationLink {
                ReportsView()
            } label: {
                frameButton("list.bullet", overPhoto: overPhoto)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)
            locationChip(overPhoto: overPhoto)
            Spacer(minLength: 8)

            if model.photo == nil {
                Button { model.showingSettings = true } label: {
                    frameButton("gearshape", overPhoto: overPhoto)
                }
                .buttonStyle(.plain)
            } else {
                // With a photo in the frame, discarding it is the thing somebody
                // reaches for. Settings is one screen further on, and this is
                // the last chance to reject a blurred shot cheaply.
                Button { model.photo = nil } label: {
                    frameButton("xmark", overPhoto: overPhoto)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 58)
    }

    @ViewBuilder private func frameButton(_ systemImage: String, overPhoto: Bool) -> some View {
        let glyph = Image(systemName: systemImage)
            .font(.system(size: 18, weight: .medium))

        if overPhoto {
            glyph
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(.white.opacity(0.16), in: .circle)
                .overlay { Circle().strokeBorder(.white.opacity(0.32), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
        } else {
            glyph
                .foregroundStyle(Repara.ink)
                .frame(width: 48, height: 48)
                .glassEffect(.regular.interactive(), in: .circle)
        }
    }

    /// Accuracy, over the frame rather than in a row of its own: it is context
    /// for the photo, and the pin gets placed properly on the next screen anyway.
    @ViewBuilder private func locationChip(overPhoto: Bool) -> some View {
        // Bright cyan over a photograph, the palette's blue over the canvas —
        // "located" has to read as located against either background.
        let fixColour: Color =
            overPhoto ? Color(red: 0.353, green: 0.784, blue: 0.980) : Repara.headsUp
        let content = HStack(spacing: 7) {
            Image(systemName: locationIcon)
                .font(.footnote)
                .foregroundStyle(
                    model.location.coordinate == nil
                        ? AnyShapeStyle(.tertiary) : AnyShapeStyle(fixColour))
            Text(locationLabel)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)

        // The chip sits between two 48 pt buttons and must give way to them: an
        // accuracy reading is worth less than the button that leaves this
        // screen, and without this it pushed the trailing one off the edge.
        if overPhoto {
            content
                .foregroundStyle(.white)
                .background(.white.opacity(0.16), in: .capsule)
                .overlay { Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5) }
                .layoutPriority(-1)
        } else {
            content
                .glassEffect(.regular, in: .capsule)
                .layoutPriority(-1)
        }
    }

    private var locationIcon: String {
        if model.location.coordinate != nil { return "location.fill" }
        return model.location.failure == nil ? "location" : "location.slash"
    }

    /// Short, because it shares a row with two buttons. What the accuracy is
    /// *for* is said once in the frame footnote instead of on every launch.
    private var locationLabel: String {
        if let accuracy = model.location.accuracy, model.location.coordinate != nil {
            return "±\(Int(accuracy.rounded())) m"
        }
        if model.location.failure != nil { return "No location yet" }
        return "Finding you…"
    }

    // MARK: The bottom third

    private var controls: some View {
        VStack(spacing: 12) {
            if model.photo == nil {
                shutterRow
            } else {
                noteRow
                draftButtons
            }

            if let error = model.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Repara.stop)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            if !model.hasAPIKey {
                Text(
                    "Add a \(model.providerName) API key in Settings to draft automatically, or "
                        + "write the report yourself."
                )
                .reparaFootnote()
            }
        }
        .padding(16)
        .background(Repara.canvas)
    }

    /// 68 pt shutter, 68 pt library button. Both thumb-sized, both in the
    /// bottom third, and the library one is not a lesser affordance — the
    /// simulator has no camera and plenty of problems get photographed before
    /// somebody thinks to report them.
    private var shutterRow: some View {
        HStack(spacing: 14) {
            Button {
                showingCamera = true
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 22))
                    Text("Take the photo")
                        .font(.system(size: 20, weight: .semibold))
                }
                .foregroundStyle(Repara.onInk)
                .frame(maxWidth: .infinity, minHeight: 68)
                .background(Repara.ink, in: .capsule)
                .shadow(color: Repara.ink.opacity(0.3), radius: 12, y: 6)
            }
            .buttonStyle(.plain)

            PhotosPicker(selection: $libraryItem, matching: .images) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 22))
                    .foregroundStyle(Repara.ink)
                    .frame(width: 68, height: 68)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
        }
    }

    /// One row, collapsed, and explicitly optional.
    ///
    /// It used to be a two-section `Form` field with a paragraph under it, which
    /// made writing something feel compulsory. The model reads the photo; a note
    /// only ever adds what a photo cannot show — how long it has been there.
    @ViewBuilder private var noteRow: some View {
        @Bindable var model = model

        // Two shapes rather than one, because a `TextField` inside a `Button`
        // label is a field nobody can type into — the button eats the tap.
        Group {
            if noteExpanded || !model.userText.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(
                        "e.g. mattress dumped by the bins, been here three days",
                        text: $model.userText,
                        axis: .vertical
                    )
                    .font(.body)
                    .lineLimit(1...4)
                    .focused($editingNote)

                    Text(
                        "Any language — the report is drafted in Portuguese and you read it before "
                            + "it is filed."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { noteExpanded = true }
                    editingNote = true
                } label: {
                    HStack {
                        Text("Add a note — optional")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "plus")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Repara.card, in: .rect(cornerRadius: Repara.Radius.card, style: .continuous))
    }

    private var draftButtons: some View {
        VStack(spacing: 4) {
            Button {
                Task { await model.makeDraft() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20))
                        .foregroundStyle(Repara.amber)
                    Text("Draft the report")
                }
            }
            .buttonStyle(InkButtonStyle(height: 68))
            .disabled(!model.hasAPIKey)
            .opacity(model.hasAPIKey ? 1 : 0.45)

            Button("Write it myself") { model.skipDraft() }
                .font(.body)
                .foregroundStyle(Repara.ink)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
    }
}

// MARK: - Camera

/// `UIImagePickerController` rather than a hand-rolled AVFoundation session:
/// it is the system camera, so focus, exposure, zoom and the volume-button
/// shutter all work as the user expects, and there is no capture code of ours
/// to get wrong. The library picker above covers the simulator, which has no
/// camera at all.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera)
            ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
        UINavigationControllerDelegate
    {
        private let onCapture: (UIImage) -> Void
        private let dismiss: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, dismiss: @escaping () -> Void) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { onCapture(image) }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
