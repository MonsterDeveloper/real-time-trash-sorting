//
//  BinCategory.swift
//  real-time-trash-sorter
//
//  Maps the raw labels emitted by TrashSorterDEModel onto German waste-bin
//  presentation: display name, a short hint, an SF Symbol and a system color.
//

import SwiftUI

/// One of the four German waste bins the model can predict.
enum BinCategory: String, CaseIterable, Identifiable, Sendable {
    case blaueTonne = "blaue_tonne"
    case glas = "glas"
    case restmuell = "restmuell"
    case wertstofftonne = "wertstofftonne"

    var id: String { rawValue }

    /// Resolve a Vision classification identifier into a known bin.
    init?(rawLabel: String) {
        self.init(rawValue: rawLabel.lowercased())
    }

    /// German bin name shown to the user.
    var displayName: String {
        switch self {
        case .blaueTonne: "Blaue Tonne"
        case .glas: "Glas"
        case .restmuell: "Restmüll"
        case .wertstofftonne: "Wertstofftonne"
        }
    }

    /// Short German hint describing what belongs in the bin.
    var hint: String {
        switch self {
        case .blaueTonne: "Papier & Pappe"
        case .glas: "Glasverpackungen"
        case .restmuell: "Nicht recycelbar"
        case .wertstofftonne: "Kunststoff & Metall"
        }
    }

    /// SF Symbol representing the bin.
    var symbolName: String {
        switch self {
        case .blaueTonne: "newspaper.fill"
        case .glas: "wineglass.fill"
        case .restmuell: "trash.fill"
        case .wertstofftonne: "arrow.3.trianglepath"
        }
    }

    /// System color used to tint the bin throughout the UI.
    var tint: Color {
        switch self {
        case .blaueTonne: .blue
        case .glas: .mint
        case .restmuell: .gray
        case .wertstofftonne: .yellow
        }
    }
}

/// The result of running the classifier on a captured image.
struct Classification: Identifiable, Sendable {
    let id = UUID()
    let category: BinCategory
    /// Confidence as a fraction in the range 0...1.
    let confidence: Double
    /// The raw label returned by the model (useful for debugging).
    let rawLabel: String
}
