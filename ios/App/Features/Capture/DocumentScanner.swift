#if os(iOS)
import SwiftUI
import VisionKit
// `jpegData(compressionQuality:)` on the scanned `UIImage` comes from UIKit.
import UIKit

/// Wraps `VNDocumentCameraViewController`.
///
/// Chosen over a hand-rolled AVFoundation camera because it already does what
/// ANA-PLAN §8.1 asks for — finds the page edges, corrects perspective and
/// rotation — and it supports batch capture (§8.3) without the shutter waiting
/// on anything.
struct DocumentScanner: UIViewControllerRepresentable {
    /// Called once per scanning session with every page the user shot.
    var onFinish: ([Data]) -> Void
    var onCancel: () -> Void
    var onError: (Error) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onCancel: onCancel, onError: onError)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([Data]) -> Void
        let onCancel: () -> Void
        let onError: (Error) -> Void

        init(
            onFinish: @escaping ([Data]) -> Void,
            onCancel: @escaping () -> Void,
            onError: @escaping (Error) -> Void
        ) {
            self.onFinish = onFinish
            self.onCancel = onCancel
            self.onError = onError
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var pages: [Data] = []
            for index in 0..<scan.pageCount {
                // 0.9 keeps enough detail for OCR while staying a sane file
                // size; §8.2 wants high resolution preserved for recognition.
                if let data = scan.imageOfPage(at: index).jpegData(compressionQuality: 0.9) {
                    pages.append(data)
                }
            }
            onFinish(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            onError(error)
        }
    }
}
#endif
