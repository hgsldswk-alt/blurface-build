import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SystemPhotoPicker: UIViewControllerRepresentable {
    var limit: Int
    var continuous: Bool
    var onSelection: ([PhotoInput]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var settings = PHPickerConfiguration()
        settings.filter = .images
        settings.preferredAssetRepresentationMode = .current
        settings.selectionLimit = limit
        settings.selection = continuous ? .continuous : .ordered
        if continuous { settings.disabledCapabilities = [.selectionActions] }
        let picker = PHPickerViewController(configuration: settings)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {
        context.coordinator.owner = self
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var owner: SystemPhotoPicker

        init(owner: SystemPhotoPicker) { self.owner = owner }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            if owner.continuous && results.isEmpty { return }
            owner.onSelection(results.map { .picker($0.itemProvider) })
        }
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    var urls: [URL]
    var completion: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in completion() }
        }
        return controller
    }

    func updateUIViewController(_ view: UIActivityViewController, context: Context) {}
}

struct SaveFilesSheet: UIViewControllerRepresentable {
    var urls: [URL]
    var completion: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ view: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Bool) -> Void
        init(_ completion: @escaping (Bool) -> Void) { self.completion = completion }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(!urls.isEmpty)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(false) }
    }
}
