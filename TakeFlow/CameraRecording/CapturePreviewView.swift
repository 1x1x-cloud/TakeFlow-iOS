@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct CaptureFocusRequest: Equatable {
    let id: UUID
    let screenPoint: CGPoint
    let indicatorPoint: CGPoint
}

enum CapturePreviewPointConverter {
    static func convert(
        screenPoint: CGPoint,
        previewFrameInWindow: CGRect,
        devicePointForLayerPoint: (CGPoint) -> CGPoint
    ) -> NormalizedCapturePoint? {
        let layerPoint = CGPoint(
            x: screenPoint.x - previewFrameInWindow.minX,
            y: screenPoint.y - previewFrameInWindow.minY
        )
        guard CGRect(origin: .zero, size: previewFrameInWindow.size)
            .contains(layerPoint)
        else {
            return nil
        }
        let converted = devicePointForLayerPoint(layerPoint)
        return NormalizedCapturePoint(
            x: converted.x,
            y: converted.y
        )
    }
}

struct CapturePreviewView: UIViewRepresentable {
    let source: CapturePreviewSource
    let mirrored: Bool
    let focusRequest: CaptureFocusRequest?
    let onFocus:
        (_ point: NormalizedCapturePoint, _ requestID: UUID) -> Void
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
        private var handledFocusRequestID: UUID?

        init(parent: CapturePreviewView) {
            self.parent = parent
        }

        func attach(to view: CapturePreviewUIView) {
            self.view = view
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
            applyFocusRequest(to: view)
        }

        private func applyFocusRequest(to view: CapturePreviewUIView) {
            guard
                let request = parent.focusRequest,
                request.id != handledFocusRequestID,
                let window = view.window
            else {
                return
            }
            let frameInWindow = view.convert(view.bounds, to: window)
            guard let devicePoint = CapturePreviewPointConverter.convert(
                screenPoint: request.screenPoint,
                previewFrameInWindow: frameInWindow,
                devicePointForLayerPoint: {
                    view.previewLayer.captureDevicePointConverted(
                        fromLayerPoint: $0
                    )
                }
            ) else {
                handledFocusRequestID = request.id
                return
            }
            handledFocusRequestID = request.id
            parent.onFocus(devicePoint, request.id)
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
    }

    required init?(coder: NSCoder) {
        nil
    }
}
