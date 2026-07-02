//
//  LabelOCR.swift
//  real-time-trash-sorter
//
//  Runs on-device text recognition on the label close-up photo using the
//  modern Swift Vision API (`RecognizeTextRequest`). Debug read-out only —
//  no fusion into the Pfand verdict yet.
//

import UIKit
import Vision

struct LabelOCRResult: Sendable {
    let lines: [String]

    var joined: String { lines.joined(separator: "\n") }
    var isEmpty: Bool { lines.isEmpty }

    static let empty = LabelOCRResult(lines: [])
}

struct LabelOCR: Sendable {
    // Pfand/recycling vocabulary to bias word recognition.
    private static let customWords = [
        "Pfand", "Einweg", "Mehrweg", "Einwegflasche", "Mehrwegflasche",
        "Pfandflasche", "Pfandsystem", "Pfandautomat", "DPG", "PET",
    ]

    func recognizeText(_ image: UIImage) async throws -> LabelOCRResult {
        guard let cgImage = image.cgImage else { throw ClassifierError.badImage }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = [
            Locale.Language(identifier: "de-DE"),
            Locale.Language(identifier: "en-US"),
        ]
        request.customWords = Self.customWords

        let observations = try await request.perform(on: cgImage, orientation: orientation)
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return LabelOCRResult(lines: lines)
    }
}
