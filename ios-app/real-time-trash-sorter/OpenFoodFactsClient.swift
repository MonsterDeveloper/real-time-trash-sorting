//
//  OpenFoodFactsClient.swift
//  real-time-trash-sorter
//
//  Looks up a scanned GTIN against the Open Food Facts (OFF) API to pull
//  product identity (name, brand, packaging, category) as corroborating
//  evidence for the Pfand verdict. OFF has no deposit field, so this is
//  never a standalone Pfand answer — debug read-out only for now.
//

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.ctoofeverything.trash", category: "OpenFoodFacts")

enum OpenFoodFactsError: LocalizedError {
    case network
    case decoding

    var errorDescription: String? {
        switch self {
        case .network: "Open Food Facts konnte nicht erreicht werden."
        case .decoding: "Antwort von Open Food Facts konnte nicht gelesen werden."
        }
    }
}

// MARK: - Decodable response models (OFF API v3)

private struct OFFResponse: Decodable {
    let code: String?
    let status: String?
    let result: OFFResult?
    let product: OFFProduct?
    let errors: [OFFError]?
    let warnings: [OFFError]?
}

private struct OFFResult: Decodable {
    let id: String?
    let name: String?
}

private struct OFFError: Decodable {
    let message: OFFErrorMessage?
}

private struct OFFErrorMessage: Decodable {
    let id: String?
    let lcMessage: String?

    enum CodingKeys: String, CodingKey {
        case id
        case lcMessage = "lc_message"
    }
}

private struct OFFProduct: Decodable {
    let productName: String?
    let brands: String?
    let quantity: String?
    let categoriesTags: [String]?
    let packagings: [OFFPackaging]?
    let imageSmallURL: URL?

    enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case brands
        case quantity
        case categoriesTags = "categories_tags"
        case packagings
        case imageSmallURL = "image_front_small_url"
    }
}

private struct OFFPackaging: Decodable {
    let material: OFFTaxonomyRef?
    let shape: OFFTaxonomyRef?
    let recycling: OFFTaxonomyRef?
}

// v3 represents packaging material/shape/recycling as taxonomy references
// (e.g. `{"id": "en:aluminium"}`), not plain strings.
private struct OFFTaxonomyRef: Decodable {
    let id: String?
}

// MARK: - App-facing value type

struct OpenFoodFactsProduct: Sendable {
    let name: String?
    let brand: String?
    let quantity: String?
    let categories: [String]
    let packagingMaterials: [String]
    let imageURL: URL?

    var debugSummary: String {
        """
        name:   \(name ?? "–")
        brand:  \(brand ?? "–")
        menge:  \(quantity ?? "–")
        verp.:  \(packagingMaterials.isEmpty ? "–" : packagingMaterials.joined(separator: ", "))
        kat.:   \(categories.isEmpty ? "–" : categories.joined(separator: ", "))
        """
    }
}

// MARK: - Client

struct OpenFoodFactsClient: Sendable {
    private static let baseURL = "https://world.openfoodfacts.org/api/v3/product/"
    private static let userAgent = "RealTimeTrashSorter/1.0 (me@ctoofeverything.dev)"
    private static let fields = "product_name,brands,quantity,packagings,categories_tags,image_front_small_url,code"

    func lookup(_ barcode: String) async throws -> OpenFoodFactsProduct? {
        guard var components = URLComponents(string: Self.baseURL + "\(barcode).json") else {
            throw OpenFoodFactsError.network
        }
        components.queryItems = [
            URLQueryItem(name: "fields", value: Self.fields),
            URLQueryItem(name: "lc", value: "de"),
        ]
        guard let url = components.url else { throw OpenFoodFactsError.network }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        log.debug("Requesting \(url.absoluteString, privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            log.error("Network request failed for GTIN \(barcode, privacy: .public): \(error, privacy: .public)")
            throw OpenFoodFactsError.network
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let rawBody = String(data: data, encoding: .utf8) ?? "<non-UTF8 body, \(data.count) bytes>"
        log.debug("HTTP \(statusCode) for GTIN \(barcode, privacy: .public) — body: \(rawBody, privacy: .public)")

        guard statusCode == 200 || statusCode == 404 else {
            log.error("Unexpected HTTP status \(statusCode) for GTIN \(barcode, privacy: .public)")
            throw OpenFoodFactsError.network
        }

        let decoded: OFFResponse
        do {
            decoded = try JSONDecoder().decode(OFFResponse.self, from: data)
        } catch {
            log.error("Decoding failed for GTIN \(barcode, privacy: .public): \(error, privacy: .public)")
            throw OpenFoodFactsError.decoding
        }

        guard statusCode == 200, decoded.result?.id == "product_found", let product = decoded.product else {
            let errorMessages = (decoded.errors ?? []).compactMap { $0.message?.lcMessage ?? $0.message?.id }
            log.info("""
                Miss for GTIN \(barcode, privacy: .public) — \
                httpStatus: \(statusCode, privacy: .public), \
                status: \(decoded.status ?? "unknown", privacy: .public), \
                result.id: \(decoded.result?.id ?? "unknown", privacy: .public), \
                result.name: \(decoded.result?.name ?? "–", privacy: .public), \
                echoedCode: \(decoded.code ?? "–", privacy: .public), \
                errors: \(errorMessages.isEmpty ? "none" : errorMessages.joined(separator: "; "), privacy: .public)
                """)
            return nil
        }

        log.info("Hit for GTIN \(barcode, privacy: .public) — name: \(product.productName ?? "–", privacy: .public)")

        return OpenFoodFactsProduct(
            name: product.productName,
            brand: product.brands,
            quantity: product.quantity,
            categories: product.categoriesTags ?? [],
            packagingMaterials: (product.packagings ?? []).compactMap(\.material?.id),
            imageURL: product.imageSmallURL
        )
    }
}
