//
//  CameraManager.swift
//  real-time-trash-sorter
//
//  Wraps an AVCaptureSession for still-photo capture with flash control and
//  front/back switching. Session work runs on a dedicated queue; UI-facing state
//  is published on the main actor via @Observable.
//

import AVFoundation
import Observation
import UIKit

@Observable
@MainActor
final class CameraManager {
    enum Status {
        case unconfigured
        case authorized
        case denied
        case failed
    }

    /// Authorization / configuration state, drives the camera-denied fallback UI.
    private(set) var status: Status = .unconfigured
    /// Flash mode applied to the next capture. Bound directly by the UI.
    var flashMode: AVCaptureDevice.FlashMode = .off
    /// Which camera is currently active.
    private(set) var cameraPosition: AVCaptureDevice.Position = .back
    /// Current zoom factor of the active camera (1.0 == no zoom).
    private(set) var zoomFactor: CGFloat = 1.0

    /// The session backing the preview layer.
    @ObservationIgnored let session = AVCaptureSession()

    // Upper bound on zoom so digital zoom never gets unusably grainy.
    @ObservationIgnored private let maxZoomCap: CGFloat = 8.0

    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "dev.ctoofeverything.camera.session")
    @ObservationIgnored private var videoInput: AVCaptureDeviceInput?
    @ObservationIgnored private var isConfigured = false
    // Held strongly so the capture delegate survives until the photo completes.
    @ObservationIgnored private var activeProcessor: PhotoCaptureProcessor?

    // MARK: - Lifecycle

    /// Request access, configure the session once, and start running.
    func configure() async {
        guard await requestAuthorization() else {
            status = .denied
            return
        }
        status = .authorized

        if !isConfigured {
            isConfigured = true
            configureSession()
        }
        start()
    }

    func start() {
        let session = self.session
        sessionQueue.async {
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: - Controls

    /// Largest zoom factor offered to the UI for the active camera.
    var maxZoomFactor: CGFloat {
        guard let device = videoInput?.device else { return maxZoomCap }
        return min(device.maxAvailableVideoZoomFactor, maxZoomCap)
    }

    /// Set the zoom factor, clamped to what the active camera supports.
    func setZoom(_ factor: CGFloat) {
        guard let device = videoInput?.device else { return }
        let clamped = min(max(factor, device.minAvailableVideoZoomFactor), maxZoomFactor)
        zoomFactor = clamped
        sessionQueue.async {
            guard let _ = try? device.lockForConfiguration() else { return }
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        }
    }

    /// Toggle between the back and front cameras.
    func switchCamera() {
        let newPosition: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
        cameraPosition = newPosition
        zoomFactor = 1.0

        let session = self.session
        let currentInput = self.videoInput
        sessionQueue.async { [weak self] in
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            if let currentInput { session.removeInput(currentInput) }

            guard
                let device = Self.device(for: newPosition),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else {
                // Re-add the previous input so we are not left with no camera.
                if let currentInput, session.canAddInput(currentInput) {
                    session.addInput(currentInput)
                }
                return
            }
            session.addInput(input)
            Task { @MainActor in self?.videoInput = input }
        }
    }

    /// Capture a single still photo, applying the current flash mode.
    func capturePhoto() async throws -> UIImage {
        let settings = AVCapturePhotoSettings()
        if photoOutput.supportedFlashModes.contains(flashMode) {
            settings.flashMode = flashMode
        }

        let photoOutput = self.photoOutput
        return try await withCheckedThrowingContinuation { continuation in
            let processor = PhotoCaptureProcessor(continuation: continuation) { [weak self] in
                Task { @MainActor in self?.activeProcessor = nil }
            }
            activeProcessor = processor
            sessionQueue.async {
                photoOutput.capturePhoto(with: settings, delegate: processor)
            }
        }
    }

    // MARK: - Private

    private func requestAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    private func configureSession() {
        let session = self.session
        let photoOutput = self.photoOutput
        let position = self.cameraPosition

        sessionQueue.async { [weak self] in
            session.beginConfiguration()
            session.sessionPreset = .photo

            guard
                let device = Self.device(for: position),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else {
                session.commitConfiguration()
                Task { @MainActor in self?.status = .failed }
                return
            }
            session.addInput(input)

            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                photoOutput.maxPhotoQualityPrioritization = .balanced
            }
            session.commitConfiguration()
            Task { @MainActor in self?.videoInput = input }
        }
    }

    nonisolated private static func device(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
    }
}

/// Bridges the AVCapturePhotoCaptureDelegate callback into an async continuation.
private final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let continuation: CheckedContinuation<UIImage, Error>
    private let onFinish: () -> Void

    init(continuation: CheckedContinuation<UIImage, Error>, onFinish: @escaping () -> Void) {
        self.continuation = continuation
        self.onFinish = onFinish
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: (any Error)?
    ) {
        defer { onFinish() }

        if let error {
            continuation.resume(throwing: error)
            return
        }
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            continuation.resume(throwing: ClassifierError.badImage)
            return
        }
        continuation.resume(returning: image)
    }
}
