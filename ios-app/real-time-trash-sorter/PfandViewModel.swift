//
//  PfandViewModel.swift
//  real-time-trash-sorter
//

import Observation
import SwiftUI

/// Non-fatal errors from the individual detection stages, surfaced to the user
/// alongside the result rather than silently swallowed.
struct PfandDiagnostics: Sendable {
    let ocrError: String?
    let barcodeError: String?
    let offError: String?

    static let none = PfandDiagnostics(ocrError: nil, barcodeError: nil, offError: nil)
}

@Observable
@MainActor
final class PfandViewModel {
    enum Step {
        case awaitingBottlePhoto
        case awaitingLabelPhoto(UIImage)
        case processing(bottle: UIImage, label: UIImage)
        case result(bottle: UIImage, label: UIImage, ContainerTypeDetection, LabelOCRResult, LabelBarcodeResult, OpenFoodFactsProduct?, PfandOutcome, PfandDiagnostics)
    }

    private(set) var step: Step = .awaitingBottlePhoto
    private(set) var errorMessage: String?
    private(set) var captureFeedbackTrigger = 0
    private(set) var resultFeedbackTrigger = 0

    private let detector = try? ContainerTypeObjectDetector()
    private let ocr = LabelOCR()
    private let barcode = LabelBarcode()
    private let off = OpenFoodFactsClient()
    private let aggregator = PfandAggregator()

    var bottleImage: UIImage? {
        switch step {
        case .awaitingLabelPhoto(let img):          img
        case .processing(let img, _):               img
        case .result(let img, _, _, _, _, _, _, _): img
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

        guard let detector else {
            showError("Modell konnte nicht geladen werden.")
            return
        }

        do {
            // Run container type detection (bottle photo), OCR and barcode detection (label photo) concurrently.
            async let detectionTask = detector.detect(bottleImage)
            async let ocrTask = ocr.recognizeText(labelImage)
            async let barcodeTask = barcode.detectBarcodes(labelImage)
            try? await Task.sleep(for: .milliseconds(950))
            let detection = try await detectionTask

            let ocrResult: LabelOCRResult
            var ocrError: String?
            do {
                ocrResult = try await ocrTask
            } catch {
                ocrResult = .empty
                ocrError = error.localizedDescription
            }

            let barcodeResult: LabelBarcodeResult
            var barcodeError: String?
            do {
                barcodeResult = try await barcodeTask
            } catch {
                barcodeResult = .empty
                barcodeError = error.localizedDescription
            }

            // OFF lookup depends on the decoded barcode, so it runs only after barcode detection
            // resolves. Only GTIN symbologies (EAN-13/EAN-8/UPC-E) identify products — QR/Code128
            // payloads on a Pfand label aren't product barcodes.
            let productBarcode = barcodeResult.barcodes.first { candidate in
                let symbology = candidate.symbology.lowercased()
                return symbology.contains("ean13") || symbology.contains("ean8") || symbology.contains("upce")
            }
            var offResult: OpenFoodFactsProduct?
            var offError: String?
            if let payload = productBarcode?.payload {
                do {
                    offResult = try await off.lookup(payload)
                } catch {
                    offError = error.localizedDescription
                }
            }

            // Run 4: fuse the signals above into a final verdict with the on-device LLM.
            let outcome = await aggregator.aggregate(
                containerType: detection,
                ocr: ocrResult,
                barcode: barcodeResult,
                off: offResult,
                bottleImage: bottleImage,
                labelImage: labelImage
            )
            let diagnostics = PfandDiagnostics(ocrError: ocrError, barcodeError: barcodeError, offError: offError)

            resultFeedbackTrigger += 1
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                step = .result(bottle: bottleImage, label: labelImage, detection, ocrResult, barcodeResult, offResult, outcome, diagnostics)
            }
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
