//
//  CaptureViewModel.swift
//  real-time-trash-sorter
//
//  Drives the capture -> process -> result -> auto-hide flow and owns the
//  classifier. UI reads `phase`, `capturedImage` and `result` to render.
//

import Observation
import SwiftUI

@Observable
@MainActor
final class CaptureViewModel {
    enum Phase: Equatable {
        case idle
        case captured
        case processing
        case result
    }

    private(set) var phase: Phase = .idle
    private(set) var capturedImage: UIImage?
    private(set) var result: Classification?
    private(set) var errorMessage: String?

    /// Bumped to fire sensory feedback at the right moments.
    private(set) var captureFeedbackTrigger = 0
    private(set) var resultFeedbackTrigger = 0

    private let classifier = try? TrashClassifier()

    // Timing constants tuned so the animation reads clearly.
    private let popToProcessingDelay: Duration = .milliseconds(260)
    private let minimumProcessingDuration: Duration = .milliseconds(950)
    private let resultHoldDuration: Duration = .seconds(2.6)

    /// Run the full capture flow. Ignored if a capture is already in progress.
    func capture(using camera: CameraManager) async {
        guard phase == .idle else { return }
        guard let classifier else {
            showError("Modell konnte nicht geladen werden.")
            return
        }

        captureFeedbackTrigger += 1

        do {
            let image = try await camera.capturePhoto()
            capturedImage = image
            withAnimation(.bouncy(duration: 0.5, extraBounce: 0.15)) {
                phase = .captured
            }

            try? await Task.sleep(for: popToProcessingDelay)
            withAnimation(.easeInOut(duration: 0.25)) {
                phase = .processing
            }

            // Run inference and a minimum delay together so the shimmer is visible.
            async let classificationTask = classifier.classify(image)
            try? await Task.sleep(for: minimumProcessingDuration)
            let classification = try await classificationTask

            result = classification
            resultFeedbackTrigger += 1
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                phase = .result
            }

            try? await Task.sleep(for: resultHoldDuration)
            // Only auto-hide if this result is still on screen.
            if phase == .result {
                reset()
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func reset() {
        withAnimation(.easeInOut(duration: 0.4)) {
            phase = .idle
            capturedImage = nil
            result = nil
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        reset()
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if errorMessage == message { errorMessage = nil }
        }
    }
}
