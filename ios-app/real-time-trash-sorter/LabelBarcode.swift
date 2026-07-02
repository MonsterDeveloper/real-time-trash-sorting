//
//  LabelBarcode.swift
//  real-time-trash-sorter
//
//  Runs on-device barcode detection on the label close-up photo using the
//  modern Swift Vision API (`DetectBarcodesRequest`). Debug read-out only —
//  no fusion into the Pfand verdict yet.
//

import UIKit
import Vision

struct DecodedBarcode: Sendable {
    let payload: String
    let symbology: String
    let confidence: Float
}

struct LabelBarcodeResult: Sendable {
    let barcodes: [DecodedBarcode]

    var isEmpty: Bool { barcodes.isEmpty }

    static let empty = LabelBarcodeResult(barcodes: [])
}

struct LabelBarcode: Sendable {
    func detectBarcodes(_ image: UIImage) async throws -> LabelBarcodeResult {
        guard let cgImage = image.cgImage else { throw ClassifierError.badImage }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        var request = DetectBarcodesRequest()
        request.symbologies = [.ean13, .ean8, .upce, .code128, .qr]

        let observations = try await request.perform(on: cgImage, orientation: orientation)
        let barcodes = observations.compactMap { obs -> DecodedBarcode? in
            guard let payload = obs.payloadString else { return nil }
            return DecodedBarcode(payload: payload,
                                   symbology: String(describing: obs.symbology),
                                   confidence: obs.confidence)
        }
        return LabelBarcodeResult(barcodes: barcodes)
    }
}
