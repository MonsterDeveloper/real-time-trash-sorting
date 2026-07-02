//
//  PfandAggregator.swift
//  real-time-trash-sorter
//
//  Run 4 — fuses the pre-computed signals (Run A container type, Run 2 OCR,
//  Run 3 barcode/Open Food Facts) into a single Pfand verdict using the
//  on-device System Language Model. A confident detector/OCR signal always
//  outranks the model's own read of the (currently text-only) evidence.
//
//  The deposit AMOUNT is never produced by the model — VerpackG §31 fixes
//  it by law, so `PfandOutcome.amountText` comes only from `resolve(...)`,
//  a deterministic table keyed on the model's system classification.
//

import FoundationModels
import OSLog
import UIKit

private let log = Logger(subsystem: "dev.ctoofeverything.trash", category: "PfandAggregator")

// MARK: - LLM output schema (classification only, no amount)

@Generable
enum PfandSystem: Sendable, Equatable {
    case einweg
    case mehrweg
    case none
    case unsure
}

@Generable
enum PfandConfidence: Sendable, Equatable {
    case high
    case medium
    case low
}

@Generable
struct PfandVerdict: Sendable {
    @Guide(description: "The deposit system this container falls under.")
    var system: PfandSystem
    @Guide(description: "Confidence that the system classification is correct.")
    var confidence: PfandConfidence
    @Guide(description: "One short sentence, in German, explaining the decision for the user.")
    var rationale: String
}

// MARK: - Deterministic outcome (amount/return — fixed by law, never generated)

struct PfandOutcome: Sendable {
    let isPfand: Bool
    let amountText: String
    let returnLocation: String
    let system: PfandSystem
    let confidence: PfandConfidence
    let rationale: String
    let isFallback: Bool
    /// Why the rule fallback was used instead of the LLM verdict, or why the LLM
    /// verdict itself is suspect. `nil` when the LLM verdict was used as-is.
    let llmError: String?
}

// MARK: - Aggregator

struct PfandAggregator: Sendable {
    func aggregate(
        containerType: ContainerTypeDetection,
        ocr: LabelOCRResult,
        barcode: LabelBarcodeResult,
        off: OpenFoodFactsProduct?,
        bottleImage: UIImage,
        labelImage: UIImage
    ) async -> PfandOutcome {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            let reasonMessage = Self.describe(model.availability)
            log.notice("SystemLanguageModel unavailable (\(String(describing: model.availability), privacy: .public)) — using rule fallback")
            let verdict = Self.ruleFallback(containerType: containerType, ocr: ocr)
            log.debug("Rule fallback verdict: \(String(describing: verdict), privacy: .public)")
            return Self.resolve(verdict: verdict, isFallback: true, llmError: reasonMessage)
        }

        do {
            let session = LanguageModelSession(
                model: model,
                tools: [],
                instructions: Instructions { Self.systemInstructions }
            )
            let options = GenerationOptions(sampling: .greedy, temperature: 0.0)
            let signalBlock = Self.buildSignalBlock(containerType: containerType, ocr: ocr, barcode: barcode, off: off)
            log.debug("LLM prompt signals:\n\(signalBlock, privacy: .public)")

            let response = try await session.respond(
                generating: PfandVerdict.self,
                options: options,
                prompt: { Self.buildPrompt(signalBlock: signalBlock) }
            )
            let verdict = response.content
            log.info("LLM raw verdict: system=\(String(describing: verdict.system), privacy: .public) confidence=\(String(describing: verdict.confidence), privacy: .public) rationale=\"\(verdict.rationale, privacy: .public)\"")
            log.debug("LLM raw response object: \(String(describing: response), privacy: .public)")

            // The rule fallback never answers "unsure" for a can/plastic/glass bottle (only for
            // signals it can't parse at all) — it always has a concrete default per material. So
            // whenever the LLM itself lands on "unsure" or low confidence, prefer the deterministic
            // heuristic over surfacing an unhelpful "Pfand unklar" that the underlying reasoning
            // usually didn't even support (the model's own rationale often argues for a concrete
            // system while still emitting "unsure" in the structured field).
            if verdict.confidence == .low || verdict.system == .unsure {
                log.notice("LLM verdict is low-confidence or unsure (system=\(String(describing: verdict.system), privacy: .public)) — using rule fallback")
                let fallback = Self.ruleFallback(containerType: containerType, ocr: ocr)
                log.debug("Rule fallback verdict: \(String(describing: fallback), privacy: .public)")
                return Self.resolve(verdict: fallback, isFallback: true, llmError: "LLM-Verdikt unsicher — Regel-Fallback verwendet.")
            }
            return Self.resolve(verdict: verdict, isFallback: false, llmError: nil)
        } catch {
            log.error("LLM call failed: \(error, privacy: .public) — using rule fallback")
            let verdict = Self.ruleFallback(containerType: containerType, ocr: ocr)
            log.debug("Rule fallback verdict: \(String(describing: verdict), privacy: .public)")
            return Self.resolve(verdict: verdict, isFallback: true, llmError: "LLM-Anfrage fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    // MARK: - Availability diagnostics

    private static func describe(_ availability: SystemLanguageModel.Availability) -> String {
        guard case .unavailable(let reason) = availability else {
            return "Sprachmodell nicht verfügbar."
        }
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence ist nicht aktiviert (Einstellungen → Apple Intelligence & Siri)."
        case .deviceNotEligible:
            return "Dieses Gerät unterstützt Apple Intelligence nicht."
        case .modelNotReady:
            return "Das Sprachmodell wird noch heruntergeladen oder vorbereitet."
        @unknown default:
            return "Sprachmodell nicht verfügbar (\(String(describing: reason)))."
        }
    }

    // MARK: - System instructions (English, per project convention for the LLM prompt)

    private static let systemInstructions = """
    You are a deposit ("Pfand") classification assistant for a German recycling app. Your job is to \
    fuse pre-computed on-device signals into a single classification of the deposit system that a \
    scanned beverage container falls under. The two photos you may receive are corroborating context \
    only — the structured signals (container type, OCR text, barcode, product identity) are the primary \
    evidence, and a confident signal always outranks your own reading of the pixels.

    Never invent or state a monetary amount — that is computed separately by fixed legal rules, not by \
    you. Only output the structured verdict fields you are asked for.

    German deposit law (VerpackG §31) facts to apply:
    - "Einweg" (single-use) deposit of €0.25 applies to: cans, and single-use plastic or glass bottles \
    containing 0.1–3.0 liters of a covered beverage (water, soft drinks, beer, mixed alcoholic drinks).
    - No deposit ("none") applies to: beverage cartons (Tetra Pak), wine, sparkling wine (Sekt), \
    spirits, containers outside the 0.1–3.0 liter range, and non-beverage packaging.
    - "Mehrweg" (reusable) deposit applies to reusable bottles, typically signaled by the words \
    "Mehrweg" or "Leihflasche" on the label, or a swing-top ("Bügelverschluss") glass bottle design. \
    The Mehrweg deposit amount is not fixed by law and varies by bottler.

    Important — container type alone is NOT sufficient evidence for "einweg", because "single-use" is a \
    property of the specific bottle, not of its material. Apply these explicit decision tables and do \
    NOT answer "unsure" for a can, plastic bottle, or glass bottle — one of the two rows below always \
    applies:

    Cans and plastic (PET) bottles:
      - WITH explicit mehrweg evidence (OCR mentions "Mehrweg"/"Leihflasche") → "mehrweg", confidence \
        "high".
      - WITHOUT explicit mehrweg evidence (this is the common case — most cans and PET bottles, \
        including ordinary mineral water like Volvic, Evian, or supermarket brands, are einweg even \
        though they carry no special wording) → "einweg", confidence "high". Do not reason your way into \
        "mehrweg" or "unsure" for a plain PET bottle just because the drink is water — bottled water in \
        PET is einweg by default in Germany.

    Glass bottles are the opposite of cans/PET — most German glass beverage bottles (especially craft \
    and drinks bottled by smaller/independent brands) are mehrweg pool bottles, refilled and reused, even \
    without a swing-top closure or the word "Mehrweg" printed on them — real Mehrweg glass bottles usually \
    carry NO special wording at all, since the absence of an einweg marking is itself the normal signal. \
    Because printed einweg markings (a DPG Pfand logo, or OCR text such as "Einweg", "Einwegpfand", or \
    "0,25 €") are the standard, legally-expected way to identify Einweg glass, treat their ABSENCE as \
    positive evidence for "mehrweg", not as a reason to answer "unsure":
      - Glass bottle WITH explicit einweg evidence (DPG logo confirmed, or OCR mentions "Einweg"/ \
        "Einwegpfand"/"0,25 €") → "einweg", confidence "high".
      - Glass bottle WITH explicit mehrweg evidence (OCR mentions "Mehrweg"/"Leihflasche", or a swing-top \
        design) → "mehrweg", confidence "high".
      - Glass bottle with NEITHER explicit einweg NOR explicit mehrweg evidence → "mehrweg", confidence \
        "medium" (this is the common case for independent/craft brands and is the expected default).
    - Reserve "unsure" for cases that are genuinely ambiguous — e.g. the container type itself is \
    uncertain, the volume can't be determined, or signals actively contradict each other. Do not use \
    "unsure" merely because a glass bottle lacks explicit wording; that case resolves to "mehrweg" per \
    the rule above.
    - Only report "high" confidence when a concrete signal (explicit wording, a confirmed DPG logo, or a \
    can/standard PET bottle) directly supports the verdict.
    - Your "rationale" must agree with your "system" field — if your reasoning concludes this is a \
    Mehrweg bottle, the "system" value must be "mehrweg", not "unsure" (and likewise for the other cases).

    Respond only with the requested structured verdict.
    """

    // MARK: - Prompt builder

    // Note: the on-device FoundationModels SDK (as shipped) has no image-attachment
    // API on `Prompt` — fusion runs on the structured text signals only. The photos
    // are still threaded through `aggregate(...)` so this can pick them up as
    // corroborating context without a call-site change once such an API ships.
    private static func buildSignalBlock(
        containerType: ContainerTypeDetection,
        ocr: LabelOCRResult,
        barcode: LabelBarcodeResult,
        off: OpenFoodFactsProduct?
    ) -> String {
        """
        Container type (Run A): \(containerType.type.rawValue), confidence \(String(format: "%.2f", containerType.confidence))
        DPG Pfand logo: (detection not implemented)
        OCR text (Run 2): "\(ocr.isEmpty ? "(none)" : ocr.joined)"
        Barcode (Run 3): \(barcodeSummary(barcode))
        Product identity (Open Food Facts): \(offSummary(off))
        """
    }

    private static func buildPrompt(signalBlock: String) -> Prompt {
        Prompt {
            signalBlock
        }
    }

    private static func barcodeSummary(_ barcode: LabelBarcodeResult) -> String {
        guard let first = barcode.barcodes.first else { return "(none)" }
        return "\(first.symbology) \(first.payload)"
    }

    private static func offSummary(_ off: OpenFoodFactsProduct?) -> String {
        guard let off else { return "(none)" }
        var parts: [String] = []
        if let name = off.name { parts.append("name: \(name)") }
        if let brand = off.brand { parts.append("brand: \(brand)") }
        if let quantity = off.quantity { parts.append("quantity: \(quantity)") }
        if !off.packagingMaterials.isEmpty { parts.append("packaging: \(off.packagingMaterials.joined(separator: ", "))") }
        if !off.categories.isEmpty { parts.append("categories: \(off.categories.joined(separator: ", "))") }
        return parts.isEmpty ? "(none)" : parts.joined(separator: ", ")
    }

    // MARK: - Rule fallback (no model / low confidence)

    /// Conservative, always-low-confidence verdict computed from raw signals only.
    /// Used when the System Language Model is unavailable or itself reports low confidence.
    static func ruleFallback(containerType: ContainerTypeDetection, ocr: LabelOCRResult) -> PfandVerdict {
        let text = ocr.joined.lowercased()

        if containerType.type == .carton {
            return PfandVerdict(
                system: .none,
                confidence: .low,
                rationale: "Getränkekartons sind in Deutschland nicht bepfandet."
            )
        }
        if text.contains("einweg") || text.contains("0,25") {
            return PfandVerdict(
                system: .einweg,
                confidence: .low,
                rationale: "Text auf dem Etikett deutet auf Einwegpfand hin — bitte DPG-Logo prüfen."
            )
        }
        if text.contains("mehrweg") || text.contains("leihflasche") {
            return PfandVerdict(
                system: .mehrweg,
                confidence: .low,
                rationale: "Text auf dem Etikett deutet auf Mehrwegpfand hin — bitte Flaschentyp beim Händler prüfen."
            )
        }

        // No explicit wording either way. Real Mehrweg glass bottles are normally
        // unmarked — the absence of an einweg marking is itself the usual signal —
        // while cans/PET are einweg by default. Mirrors the LLM's own instructions
        // so the two paths don't disagree on the common unmarked-glass case.
        if containerType.type == .glassBottle {
            return PfandVerdict(
                system: .mehrweg,
                confidence: .low,
                rationale: "Glasflasche ohne Einweg-Kennzeichnung — vermutlich Mehrweg-Pfand, bitte DPG-Logo prüfen."
            )
        }
        return PfandVerdict(
            system: .einweg,
            confidence: .low,
            rationale: "Dosen und PET-Flaschen sind ohne Mehrweg-Kennzeichnung in der Regel Einwegpfand."
        )
    }

    // MARK: - Deterministic resolver — the fixed VerpackG §31 amount/return table

    static func resolve(verdict: PfandVerdict, isFallback: Bool, llmError: String?) -> PfandOutcome {
        let outcome = Self.outcome(for: verdict, isFallback: isFallback, llmError: llmError)
        log.info("Resolved outcome: isPfand=\(outcome.isPfand) amount=\"\(outcome.amountText, privacy: .public)\" isFallback=\(outcome.isFallback) llmError=\(outcome.llmError ?? "nil", privacy: .public)")
        return outcome
    }

    private static func outcome(for verdict: PfandVerdict, isFallback: Bool, llmError: String?) -> PfandOutcome {
        switch verdict.system {
        case .einweg:
            return PfandOutcome(
                isPfand: true,
                amountText: "0,25 €",
                returnLocation: "Jeder Händler, der Einweg dieses Materials verkauft (Rückgabepflicht, kein Kauf nötig).",
                system: .einweg,
                confidence: verdict.confidence,
                rationale: verdict.rationale,
                isFallback: isFallback,
                llmError: llmError
            )
        case .mehrweg:
            return PfandOutcome(
                isPfand: true,
                amountText: "ca. 0,08–0,15 €",
                returnLocation: "Nur Geschäfte, die genau diesen Flaschentyp führen.",
                system: .mehrweg,
                confidence: verdict.confidence,
                rationale: verdict.rationale,
                isFallback: isFallback,
                llmError: llmError
            )
        case .none:
            return PfandOutcome(
                isPfand: false,
                amountText: "kein Pfand",
                returnLocation: "—",
                system: .none,
                confidence: verdict.confidence,
                rationale: verdict.rationale,
                isFallback: isFallback,
                llmError: llmError
            )
        case .unsure:
            return PfandOutcome(
                isPfand: false,
                amountText: "Pfand unklar — Einweg 0,25 € / Mehrweg ca. 0,08–0,15 €",
                returnLocation: "Bitte DPG-Logo und Etikett prüfen, oder im Geschäft nachfragen.",
                system: .unsure,
                confidence: verdict.confidence,
                rationale: verdict.rationale,
                isFallback: isFallback,
                llmError: llmError
            )
        }
    }
}
