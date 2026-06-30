//
//  PfandViewModel.swift
//  real-time-trash-sorter
//

import Observation
import SwiftUI

@Observable
@MainActor
final class PfandViewModel {
    enum Step {
        case awaitingBottlePhoto
        case awaitingLabelPhoto(UIImage)
        case processing(bottle: UIImage, label: UIImage)
        case result(bottle: UIImage, label: UIImage, ContainerClassification)
    }

    private(set) var step: Step = .awaitingBottlePhoto
    private(set) var errorMessage: String?
    private(set) var captureFeedbackTrigger = 0
    private(set) var resultFeedbackTrigger = 0

    private let classifier = try? ContainerTypeClassifier()

    var bottleImage: UIImage? {
        switch step {
        case .awaitingLabelPhoto(let img):        img
        case .processing(let img, _):             img
        case .result(let img, _, _):              img
        default: nil
        }
    }

    // Thumbnail is shown only while waiting for / taking the second photo, and during processing.
    var showsThumbnail: Bool {
        switch step {
        case .awaitingLabelPhoto, .processing: true
        default: false
        }
    }

    var canCapture: Bool {
        switch step {
        case .awaitingBottlePhoto: true
        case .awaitingLabelPhoto:  true
        default:                   false
        }
    }

    var isProcessing: Bool {
        if case .processing = step { return true }
        return false
    }

    func onShutter(using camera: CameraManager) {
        switch step {
        case .awaitingBottlePhoto:
            Task { await captureBottlePhoto(using: camera) }
        case .awaitingLabelPhoto:
            Task { await captureLabelPhoto(using: camera) }
        default:
            break
        }
    }

    func deleteBottlePhoto() {
        withAnimation(.easeInOut(duration: 0.35)) {
            step = .awaitingBottlePhoto
        }
    }

    func reset() {
        withAnimation(.easeInOut(duration: 0.4)) {
            step = .awaitingBottlePhoto
            errorMessage = nil
        }
    }

    // MARK: - Private

    private func captureBottlePhoto(using camera: CameraManager) async {
        captureFeedbackTrigger += 1
        do {
            let image = try await camera.capturePhoto()
            withAnimation(.bouncy(duration: 0.5, extraBounce: 0.15)) {
                step = .awaitingLabelPhoto(image)
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func captureLabelPhoto(using camera: CameraManager) async {
        guard case .awaitingLabelPhoto(let bottleImage) = step else { return }
        captureFeedbackTrigger += 1

        // Capture the close-up label photo.
        let labelImage: UIImage
        do {
            labelImage = try await camera.capturePhoto()
        } catch {
            showError(error.localizedDescription)
            return
        }

        withAnimation(.easeInOut(duration: 0.25)) {
            step = .processing(bottle: bottleImage, label: labelImage)
        }

        guard let classifier else {
            showError("Modell konnte nicht geladen werden.")
            return
        }

        do {
            // Run inference on the first (bottle overview) image only.
            async let classificationTask = classifier.classify(bottleImage)
            try? await Task.sleep(for: .milliseconds(950))
            let classification = try await classificationTask

            resultFeedbackTrigger += 1
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                step = .result(bottle: bottleImage, label: labelImage, classification)
            }

            try? await Task.sleep(for: .seconds(15))
            if case .result = step { reset() }
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        withAnimation(.easeInOut(duration: 0.4)) {
            step = .awaitingBottlePhoto
        }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if errorMessage == message { errorMessage = nil }
        }
    }
}
