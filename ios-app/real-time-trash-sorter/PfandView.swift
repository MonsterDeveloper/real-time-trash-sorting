//
//  PfandView.swift
//  real-time-trash-sorter
//

import SwiftUI

struct PfandOverlayView: View {
    let model: PfandViewModel
    let camera: CameraManager

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                topSection
                    .padding(.top, 12)
                Spacer()
            }

            // Thumbnail of the first photo, pinned above the zoom control.
            if model.showsThumbnail, let img = model.bottleImage {
                thumbnailView(img)
                    .padding(.trailing, 16)
                    .padding(.bottom, 190)
                    .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: model.showsThumbnail)
        .sheet(item: resultPayloadBinding) { payload in
            PfandResultSheet(payload: payload)
        }
    }

    // MARK: - Result sheet payload

    private var resultPayload: PfandResultPayload? {
        guard case .result(let bottle, let label, let detection, let ocr, let barcode, let off, let outcome, let diagnostics) = model.step else { return nil }
        return PfandResultPayload(bottleImage: bottle, labelImage: label, detection: detection, ocr: ocr, barcode: barcode, off: off, outcome: outcome, diagnostics: diagnostics)
    }

    // The sheet is dismissed either via the close button or a swipe-down; both
    // funnel through this binding's setter, which resets the capture flow.
    private var resultPayloadBinding: Binding<PfandResultPayload?> {
        Binding(
            get: { resultPayload },
            set: { newValue in
                if newValue == nil { model.reset() }
            }
        )
    }

    // MARK: - Top section

    private var topSection: some View {
        Group {
            if !instructionString.isEmpty {
                Text(instructionString)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .animation(.easeInOut(duration: 0.25), value: instructionString)
            }
        }
    }

    private var instructionString: String {
        switch model.step {
        case .awaitingBottlePhoto: "Fotografiere die ganze Flasche"
        case .awaitingLabelPhoto:  "Fotografiere das Etikett nah heran"
        case .processing:          "Pfand wird ermittelt …"
        case .result:              ""
        }
    }

    // MARK: - Thumbnail

    private func thumbnailView(_ image: UIImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    if model.isProcessing {
                        ShimmerOverlay(cornerRadius: 14)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)

            Button {
                model.deleteBottlePhoto()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white, .black.opacity(0.65))
            }
            .offset(x: 9, y: -9)
        }
    }
}

// MARK: - Result payload

private struct PfandResultPayload: Identifiable {
    let id = UUID()
    let bottleImage: UIImage
    let labelImage: UIImage
    let detection: ContainerTypeDetection
    let ocr: LabelOCRResult
    let barcode: LabelBarcodeResult
    let off: OpenFoodFactsProduct?
    let outcome: PfandOutcome
    let diagnostics: PfandDiagnostics
}

// MARK: - Result sheet

private struct PfandResultSheet: View {
    let payload: PfandResultPayload
    @Environment(\.dismiss) private var dismiss
    @State private var showDebug = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    verdictCard
                    if !errors.isEmpty {
                        errorsCard
                    }
                    imagesRow
                    debugSection
                }
                .padding(16)
            }
            .navigationTitle("Pfand-Ergebnis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    // MARK: - Verdict card

    private var isUnsure: Bool {
        !payload.outcome.isFallback && payload.outcome.system == .unsure
    }

    private var verdictTint: Color {
        switch payload.outcome.system {
        case .einweg: .green
        case .mehrweg: .teal
        case .none:   .gray
        case .unsure: .gray
        }
    }

    private var verdictHeadline: String {
        payload.outcome.isPfand ? "Pfand · \(payload.outcome.amountText)" : (isUnsure ? "Pfand unklar" : "Kein Pfand")
    }

    private var showsLowConfidenceBadge: Bool {
        payload.outcome.isFallback || payload.outcome.confidence != .high
    }

    private var verdictCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(verdictHeadline)
                    .font(.title.bold())
                    .foregroundStyle(verdictTint)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 12)

                if showsLowConfidenceBadge {
                    Text("unsicher")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect()
                        .foregroundStyle(.orange)
                }
            }

            Text(payload.outcome.returnLocation)
                .font(.body)
                .foregroundStyle(.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            Text(payload.outcome.rationale)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if showsLowConfidenceBadge {
                Label("Bitte zusätzlich DPG-Logo auf der Flasche prüfen.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                if let llmError = payload.outcome.llmError {
                    Label(llmError, systemImage: "apple.intelligence.badge.xmark")
                        .font(.footnote)
                        .foregroundStyle(.orange.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(verdictTint.opacity(0.5), lineWidth: 1.5)
        }
    }

    // MARK: - Errors card (always visible — not tucked into the collapsible debug section)

    private var errors: [(label: String, message: String)] {
        var items: [(label: String, message: String)] = []
        if let ocrError = payload.diagnostics.ocrError { items.append(("Texterkennung", ocrError)) }
        if let barcodeError = payload.diagnostics.barcodeError { items.append(("Barcode-Erkennung", barcodeError)) }
        if let offError = payload.diagnostics.offError { items.append(("Open Food Facts", offError)) }
        if let llmError = payload.outcome.llmError { items.append(("Pfand-Einschätzung (LLM)", llmError)) }
        return items
    }

    private var errorsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Fehler bei der Erkennung", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)

            VStack(spacing: 6) {
                ForEach(errors, id: \.label) { error in
                    DebugRow(label: error.label, value: error.message)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.red.opacity(0.35), lineWidth: 1)
        }
    }

    // MARK: - Photos

    private var imagesRow: some View {
        HStack(spacing: 10) {
            Image(uiImage: payload.bottleImage)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 160)
                .overlay {
                    BoundingBoxOverlay(
                        imageSize: payload.bottleImage.size,
                        box: payload.detection.boundingBox,
                        label: payload.detection.type.rawValue,
                        color: payload.detection.type.tint
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Image(uiImage: payload.labelImage)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Debug section (collapsible)

    private var debugSection: some View {
        DisclosureGroup(isExpanded: $showDebug) {
            VStack(spacing: 10) {
                detectionCard
                ocrCard
                barcodeCard
                offCard
            }
            .padding(.top, 12)
        } label: {
            Label("Debug-Informationen", systemImage: "wrench.and.screwdriver")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .tint(.secondary)
    }

    private var detectionCard: some View {
        let b = payload.detection.boundingBox
        return DebugCard(title: "Objekterkennung", systemImage: "viewfinder") {
            DebugRow(label: "Typ", value: payload.detection.type.displayName)
            DebugRow(label: "Konfidenz", value: String(format: "%.1f%%", payload.detection.confidence * 100))
            DebugRow(label: "Position", value: "x \(v(b.minX))  y \(v(b.minY))  ·  w \(v(b.width))  h \(v(b.height))")
        }
    }

    private func v(_ n: CGFloat) -> String { String(format: "%.2f", n) }

    private var ocrCard: some View {
        DebugCard(title: "OCR — Etikett", systemImage: "text.viewfinder") {
            if payload.ocr.isEmpty {
                DebugEmptyRow("Kein Text erkannt")
            } else {
                Text(payload.ocr.joined)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private var barcodeCard: some View {
        DebugCard(title: "Barcode — Etikett", systemImage: "barcode.viewfinder") {
            if payload.barcode.isEmpty {
                DebugEmptyRow("Kein Barcode erkannt")
            } else {
                ForEach(Array(payload.barcode.barcodes.enumerated()), id: \.offset) { _, code in
                    DebugRow(label: code.symbology, value: "\(code.payload)  ·  \(String(format: "%.0f%%", code.confidence * 100))")
                }
            }
        }
    }

    private var offCard: some View {
        DebugCard(title: "Open Food Facts", systemImage: "cart") {
            if let off = payload.off {
                HStack(alignment: .top, spacing: 12) {
                    if let imageURL = off.imageURL {
                        AsyncImage(url: imageURL) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Color.clear
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    VStack(spacing: 6) {
                        DebugRow(label: "Name", value: off.name ?? "–")
                        DebugRow(label: "Marke", value: off.brand ?? "–")
                        DebugRow(label: "Menge", value: off.quantity ?? "–")
                        if !off.packagingMaterials.isEmpty {
                            DebugRow(label: "Verpackung", value: off.packagingMaterials.joined(separator: ", "))
                        }
                        if !off.categories.isEmpty {
                            DebugRow(label: "Kategorien", value: off.categories.joined(separator: ", "))
                        }
                    }
                }

                Text("Produktdaten: Open Food Facts, ODbL")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                DebugEmptyRow("Kein Produkt gefunden")
            }
        }
    }
}

// MARK: - Debug UI components

private struct DebugCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                content
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct DebugRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minWidth: 80, alignment: .leading)

            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

private struct DebugEmptyRow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Bounding box overlay

private struct BoundingBoxOverlay: View {
    let imageSize: CGSize
    let box: CGRect       // Vision normalized coords: origin bottom-left
    let label: String
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let frame = geo.size
            // Replicate scaledToFill: scale so the image fills the frame.
            let scl = max(frame.width / imageSize.width, frame.height / imageSize.height)
            let scaledW = imageSize.width * scl
            let scaledH = imageSize.height * scl
            let xOff = (frame.width - scaledW) / 2
            let yOff = (frame.height - scaledH) / 2

            // Convert Vision coords (origin bottom-left) to SwiftUI (origin top-left).
            let rx = xOff + box.minX * scaledW
            let ry = yOff + (1 - box.maxY) * scaledH
            let rw = box.width * scaledW
            let rh = box.height * scaledH

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .stroke(color, lineWidth: 2)
                    .frame(width: rw, height: rh)
                    .offset(x: rx, y: ry)

                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(color, in: Capsule())
                    .offset(x: rx, y: max(0, ry - 20))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }
}
