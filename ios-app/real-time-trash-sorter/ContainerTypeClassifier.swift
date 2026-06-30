//
//  ContainerTypeClassifier.swift
//  real-time-trash-sorter
//

import CoreML
import OSLog
import SwiftUI
import UIKit
import Vision

private let log = Logger(subsystem: "dev.ctoofeverything.trash", category: "ContainerTypeClassifier")

enum ContainerType: String, CaseIterable, Sendable {
    case plasticBottle = "plastic_bottle"
    case glassBottle   = "glass_bottle"
    case can           = "can"
    case carton        = "carton"

    var displayName: String {
        switch self {
        case .plasticBottle: "Plastikflasche"
        case .glassBottle:   "Glasflasche"
        case .can:           "Dose"
        case .carton:        "Karton"
        }
    }

    var symbolName: String {
        switch self {
        case .plasticBottle: "waterbottle.fill"
        case .glassBottle:   "wineglass.fill"
        case .can:           "cylinder.fill"
        case .carton:        "shippingbox.fill"
        }
    }

    var tint: Color {
        switch self {
        case .plasticBottle: .teal
        case .glassBottle:   .green
        case .can:           .orange
        case .carton:        .brown
        }
    }

}

struct ContainerClassification: Sendable {
    let type: ContainerType
    let confidence: Double
    let boundingBox: CGRect
}

final class ContainerTypeClassifier: @unchecked Sendable {
    private let visionModel: VNCoreMLModel

    init() throws {
        let configuration = MLModelConfiguration()
        log.info("Loading ContainerTypeDetector model…")
        let model = try ContainerTypeDetector(configuration: configuration)
        visionModel = try VNCoreMLModel(for: model.model)
        log.info("Model loaded OK. Input description: \(model.model.modelDescription.inputDescriptionsByName, privacy: .public)")
        log.info("Output description: \(model.model.modelDescription.outputDescriptionsByName, privacy: .public)")
    }

    nonisolated func classify(_ image: UIImage) async throws -> ContainerClassification {
        log.info("classify() called — image size: \(image.size.width)×\(image.size.height), orientation: \(image.imageOrientation.rawValue)")
        guard let cgImage = image.cgImage else {
            log.error("Failed to get CGImage from UIImage")
            throw ClassifierError.badImage
        }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        log.info("CGImage size: \(cgImage.width)×\(cgImage.height), CGOrientation: \(orientation.rawValue)")
        let visionModel = self.visionModel

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNCoreMLRequest(model: visionModel) { request, error in
                    if let error {
                        log.error("VNCoreMLRequest error: \(error, privacy: .public)")
                        continuation.resume(throwing: error)
                        return
                    }
                    // Model is an object detector → VNRecognizedObjectObservation.
                    // Pick the highest-confidence detection, then read its top label.
                    guard
                        let detections = request.results as? [VNRecognizedObjectObservation],
                        let best = detections.max(by: { $0.confidence < $1.confidence }),
                        let topLabel = best.labels.first
                    else {
                        log.error("No VNRecognizedObjectObservation results. Raw: \(String(describing: request.results), privacy: .public)")
                        continuation.resume(throwing: ClassifierError.noResult)
                        return
                    }
                    log.info("Best detection: \(topLabel.identifier, privacy: .public) @ \(best.confidence), box: \(best.boundingBox.debugDescription, privacy: .public)")
                    guard let type = ContainerType(rawValue: topLabel.identifier.lowercased()) else {
                        log.error("Unknown label: '\(topLabel.identifier, privacy: .public)' — known: \(ContainerType.allCases.map(\.rawValue), privacy: .public)")
                        continuation.resume(throwing: ClassifierError.unknownLabel(topLabel.identifier))
                        return
                    }
                    continuation.resume(returning: ContainerClassification(
                        type: type,
                        confidence: Double(best.confidence),
                        boundingBox: best.boundingBox
                    ))
                }
                request.imageCropAndScaleOption = .centerCrop

                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
                do {
                    try handler.perform([request])
                } catch {
                    log.error("handler.perform failed: \(error, privacy: .public)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
