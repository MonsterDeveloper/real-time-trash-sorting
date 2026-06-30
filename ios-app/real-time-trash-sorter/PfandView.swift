//
//  PfandView.swift
//  real-time-trash-sorter
//

import SwiftUI

struct PfandOverlayView: View {
    let model: PfandViewModel
    let camera: CameraManager

    var body: some View {
        VStack(spacing: 0) {
            topSection
                .padding(.top, 12)

            Spacer()

            if case .result(let bottle, let label, let classification) = model.step {
                PfandResultView(bottleImage: bottle, labelImage: label, classification: classification)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 160)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: isResultShown)
    }

    // MARK: - Top section

    private var topSection: some View {
        ZStack(alignment: .topLeading) {
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

            if model.showsThumbnail, let img = model.bottleImage {
                thumbnailView(img)
                    .padding(.leading, 16)
                    .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: model.showsThumbnail)
    }

    private var instructionString: String {
        switch model.step {
        case .awaitingBottlePhoto: "Fotografiere die ganze Flasche"
        case .awaitingLabelPhoto:  "Fotografiere das Etikett nah heran"
        case .processing:          "Behältertyp wird erkannt …"
        case .result:              ""
        }
    }

    private var isResultShown: Bool {
        if case .result = model.step { return true }
        return false
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

// MARK: - Result view

private struct PfandResultView: View {
    let bottleImage: UIImage
    let labelImage: UIImage
    let classification: ContainerClassification

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                // First image with bounding box
                Image(uiImage: bottleImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 140)
                    .overlay {
                        BoundingBoxOverlay(
                            imageSize: bottleImage.size,
                            box: classification.boundingBox,
                            label: classification.type.rawValue,
                            color: classification.type.tint
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                // Second image (label close-up)
                Image(uiImage: labelImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            rawOutputBox
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
    }

    private var rawOutputBox: some View {
        let b = classification.boundingBox
        let text = """
label:  \(classification.type.rawValue)
conf:   \(String(format: "%.1f", classification.confidence * 100))%
bbox:   x=\(v(b.minX)) y=\(v(b.minY)) w=\(v(b.width)) h=\(v(b.height))
"""
        return Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func v(_ n: CGFloat) -> String { String(format: "%.3f", n) }
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
