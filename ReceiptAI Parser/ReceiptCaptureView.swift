//
//  ReceiptCaptureView.swift
//  ReceiptAI Parser
//
//  Entry UI for **camera** capture and **PhotosPicker** import.
//
//  PhotosPicker caveat (fixed here):
//  - SwiftUI may not re-fire `onChange` if the user picks the **same** asset again while `selection` stays set.
//  - We clear `selectedPhotoItem` in `defer` after loading so every pick produces a new change event.
//
//  `ImagePicker` wraps `UIImagePickerController`. The camera is shown with **fullScreenCover** (not a sheet) so the
//  preview fills the display; a sheet detent often clips or mislays the camera preview.
//

import PhotosUI
import SwiftUI
import UIKit

// MARK: - ReceiptCaptureView

struct ReceiptCaptureView: View {
    /// Parent supplies this closure; typically starts `ReceiptFlowViewModel.processReceiptImage`.
    let onImagePicked: (UIImage) -> Void

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isCameraPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add receipt")
                .font(.headline)

            Button {
                isCameraPresented = true
            } label: {
                CaptureActionLabel(
                    title: "Take receipt photo",
                    subtitle: "Use camera for a new scan",
                    icon: "camera.fill"
                )
            }
            .buttonStyle(.plain)

            PhotosPicker(
                selection: $selectedPhotoItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                CaptureActionLabel(
                    title: "Choose from photo library",
                    subtitle: "Import an existing receipt",
                    icon: "photo.on.rectangle.angled"
                )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .fullScreenCover(isPresented: $isCameraPresented) {
            ImagePicker(sourceType: .camera) { image in
                onImagePicked(image)
            }
            .ignoresSafeArea()
            .background(Color.black)
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            loadSelectedPhoto(item)
        }
    }

    /// Loads `Data` from PhotosPicker, builds `UIImage`, then clears selection for repeatability.
    private func loadSelectedPhoto(_ item: PhotosPickerItem) {
        Task {
            defer {
                Task { @MainActor in
                    selectedPhotoItem = nil
                }
            }

            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                return
            }
            onImagePicked(image)
        }
    }
}

// MARK: - Styled row label

private struct CaptureActionLabel: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - UIImagePickerController bridge

struct ImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImagePicked: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked, dismiss: dismiss.callAsFunction)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // Simulator often lacks `.camera`; gracefully fall back to photo library for demos.
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(sourceType) ? sourceType : .photoLibrary
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        // Camera preview assumes full-screen layout; avoids clipped / offset preview in compact presentations.
        picker.modalPresentationStyle = .fullScreen
        if picker.sourceType == .camera {
            picker.cameraCaptureMode = .photo
        }
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onImagePicked: (UIImage) -> Void
        private let dismiss: () -> Void

        init(onImagePicked: @escaping (UIImage) -> Void, dismiss: @escaping () -> Void) {
            self.onImagePicked = onImagePicked
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImagePicked(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
