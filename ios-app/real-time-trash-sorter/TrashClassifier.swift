//
//  TrashClassifier.swift
//  real-time-trash-sorter
//
//  Runs the TrashSorterDEModel CoreML classifier through Vision. The model has
//  rescaling + normalization baked in, so we hand Vision the raw image and let it
//  resize/crop to the expected 224x224 input.
//

import CoreML
import UIKit
import Vision

enum ClassifierError: LocalizedError {
    case badImage
    case noResult
    case unknownLabel(String)

    var errorDescription: String? {
        switch self {
        case .badImage: "Das Bild konnte nicht verarbeitet werden."
        case .noResult: "Keine Klassifizierung möglich."
        case .unknownLabel(let label): "Unbekannte Kategorie: \(label)."
        }
    }
}

/// Thin wrapper around the Vision + CoreML classification request.
///
/// Marked `@unchecked Sendable`: the only stored state is an immutable
/// `VNCoreMLModel` built once at init and never mutated afterwards.
final class TrashClassifier: @unchecked Sendable {
    private let visionModel: VNCoreMLModel

    init() throws {
        let configuration = MLModelConfiguration()
        let model = try TrashSorterDEModel(configuration: configuration)
        visionModel = try VNCoreMLModel(for: model.model)
    }

    /// Classify an image and return the top bin prediction.
    ///
    /// Vision's `perform` is synchronous and CPU/ANE heavy, so it runs on a
    /// background queue and bridges back through a continuation.
    nonisolated func classify(_ image: UIImage) async throws -> Classification {
        guard let cgImage = image.cgImage else { throw ClassifierError.badImage }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let visionModel = self.visionModel

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNCoreMLRequest(model: visionModel) { request, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard
                        let observations = request.results as? [VNClassificationObservation],
                        let top = observations.first
                    else {
                        continuation.resume(throwing: ClassifierError.noResult)
                        return
                    }
                    guard let category = BinCategory(rawLabel: top.identifier) else {
                        continuation.resume(throwing: ClassifierError.unknownLabel(top.identifier))
                        return
                    }
                    continuation.resume(
                        returning: Classification(
                            category: category,
                            confidence: Double(top.confidence),
                            rawLabel: top.identifier
                        )
                    )
                }
                // The model wants a centered square; let Vision crop to it.
                request.imageCropAndScaleOption = .centerCrop

                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
