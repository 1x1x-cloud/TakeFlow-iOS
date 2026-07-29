@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct CapturePreviewView: UIViewRepresentable {
    let source: CapturePreviewSource
    let mirrored: Bool
    let onFocus: (NormalizedCapturePoint) -> Void
    let onRotationAngleChanged: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> CapturePreviewUIView {
        let view = CapturePreviewUIView()
        view.accessibilityIdentifier = "capture.preview"
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(
        _ view: CapturePreviewUIView,
        context: Context
    ) {
        context.coordinator.parent = self
        context.coordinator.apply(to: view)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: CapturePreviewView
        private weak var view: CapturePreviewUIView?
        private var rotationCoordinator:
            AVCaptureDevice.RotationCoordinator?
        private var previewObservation: NSKeyValueObservation?
        private var captureObservation: NSKeyValueObservation?

        init(parent: CapturePreviewView) {
            self.parent = parent
        }

        func attach(to view: CapturePreviewUIView) {
            self.view = view
            view.onTap = { [weak self] point in
                guard let self, let view = self.view else {
                    return
                }
                let devicePoint = view.previewLayer
                    .captureDevicePointConverted(fromLayerPoint: point)
                self.parent.onFocus(
                    NormalizedCapturePoint(
                        x: devicePoint.x,
                        y: devicePoint.y
                    )
                )
            }
            apply(to: view)
        }

        func apply(to view: CapturePreviewUIView) {
            if view.previewLayer.session !== parent.source.session {
                view.previewLayer.session = parent.source.session
                installRotationCoordinator(
                    device: parent.source.device,
                    previewLayer: view.previewLayer
                )
            }
            view.previewLayer.videoGravity = .resizeAspectFill
            if let connection = view.previewLayer.connection {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = parent.mirrored
            }
        }

        private func installRotationCoordinator(
            device: AVCaptureDevice,
            previewLayer: AVCaptureVideoPreviewLayer
        ) {
            previewObservation = nil
            captureObservation = nil
            let coordinator = AVCaptureDevice.RotationCoordinator(
                device: device,
                previewLayer: previewLayer
            )
            rotationCoordinator = coordinator
            previewObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelPreview,
                options: [.initial, .new]
            ) { [weak self] coordinator, _ in
                let previewAngle =
                    coordinator.videoRotationAngleForHorizonLevelPreview
                let captureAngle =
                    coordinator.videoRotationAngleForHorizonLevelCapture
                Task { @MainActor in
                    guard
                        let self,
                        let connection = self.view?.previewLayer.connection
                    else {
                        return
                    }
                    if connection.isVideoRotationAngleSupported(
                        previewAngle
                    ) {
                        connection.videoRotationAngle = previewAngle
                    }
                    self.parent.onRotationAngleChanged(captureAngle)
                }
            }
            captureObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelCapture,
                options: [.initial, .new]
            ) { [weak self] coordinator, _ in
                let captureAngle =
                    coordinator.videoRotationAngleForHorizonLevelCapture
                Task { @MainActor in
                    self?.parent.onRotationAngleChanged(captureAngle)
                }
            }
        }
    }
}

final class CapturePreviewUIView: UIView {
    var onTap: ((CGPoint) -> Void)?

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            preconditionFailure("Capture preview must use its declared layer")
        }
        return layer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleTap(_:))
        )
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        onTap?(recognizer.location(in: self))
    }
}
