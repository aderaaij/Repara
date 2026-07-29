import PhotosUI
import ReparaCore
import SwiftUI

/// Step one: photograph the problem and say what is wrong, in any language.
struct CaptureView: View {
    @Environment(AppModel.self) private var model
    @State private var showingCamera = false
    @State private var libraryItem: PhotosPickerItem?

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                if let data = model.photo, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 260)
                        .clipShape(.rect(cornerRadius: 12))
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                        .overlay(alignment: .topTrailing) {
                            Button {
                                model.photo = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.5))
                            }
                            .padding(8)
                        }
                } else {
                    Button {
                        showingCamera = true
                    } label: {
                        Label("Take a photo", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)

                    PhotosPicker(selection: $libraryItem, matching: .images) {
                        Label("Choose from library", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                }
            } header: {
                Text("Photo")
            } footer: {
                Text("The council gets the full-resolution original — that is the evidence a worker acts on. A smaller copy goes to Claude to identify what it is.")
            }

            Section {
                TextField(
                    "e.g. mattress dumped by the bins, been here three days",
                    text: $model.userText,
                    axis: .vertical
                )
                .lineLimit(3...6)
            } header: {
                Text("What is wrong?")
            } footer: {
                Text("Any language. Claude translates it into the Portuguese a council worker reads, and you see that text before anything is filed.")
            }

            Section {
                LocationRow()
            }

            Section {
                Button {
                    Task { await model.makeDraft() }
                } label: {
                    Label("Draft the report", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.photo == nil || !model.hasAPIKey)

                Button("Fill it in myself") { model.skipDraft() }
                    .frame(maxWidth: .infinity)
            } footer: {
                if !model.hasAPIKey {
                    Text("Add a Claude API key in Settings to draft automatically, or fill the report in yourself.")
                        .foregroundStyle(.orange)
                }
            }

            if let error = model.error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
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
}

// MARK: - Location

struct LocationRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Image(systemName: "location.fill")
                .foregroundStyle(model.location.coordinate == nil ? Color.secondary : Color.blue)
            VStack(alignment: .leading, spacing: 2) {
                if let accuracy = model.location.accuracy, model.location.coordinate != nil {
                    Text("Located to about \(Int(accuracy)) m")
                    Text("You place the pin exactly on the next screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let failure = model.location.failure {
                    Text(failure).font(.footnote).foregroundStyle(.orange)
                } else {
                    Text("Finding you…").foregroundStyle(.secondary)
                }
            }
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
