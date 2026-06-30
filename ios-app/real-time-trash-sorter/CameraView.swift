//
//  CameraView.swift
//  real-time-trash-sorter
//
//  The single full-screen main screen: live camera preview, capture controls,
//  and the animated capture -> process -> result overlay.
//

import AVFoundation
import SwiftUI

enum AppMode {
    case trashSorting
    case pfandClassifier
}

struct CameraView: View {
    @State private var camera = CameraManager()
    @State private var model = CaptureViewModel()
    @State private var pfandModel = PfandViewModel()
    @State private var shutterFlash = false
    @State private var baseZoom: CGFloat = 1.0
    @State private var appMode: AppMode = .trashSorting

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if camera.status == .denied || camera.status == .failed {
                    CameraUnavailableView()
                } else {
                    CameraPreviewView(session: camera.session)
                        .ignoresSafeArea()
                        .gesture(zoomGesture)

                    // Dim the live feed while processing.
                    Color.black
                        .opacity(dimOpacity)
                        .ignoresSafeArea()
                        .animation(.easeInOut(duration: 0.3), value: dimOpacity)

                    // Trash sorting: captured image + result card.
                    if appMode == .trashSorting {
                        captureOverlay
                    }

                    // Pfand: instruction text, thumbnail, result card.
                    if appMode == .pfandClassifier {
                        PfandOverlayView(model: pfandModel, camera: camera)
                            .transition(.opacity)
                    }

                    controlsOverlay
                }

                // Shutter flash
                Color.white
                    .opacity(shutterFlash ? 1 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // Transient error toast
                if let message = activeErrorMessage {
                    errorToast(message)
                }
            }
            .preferredColorScheme(.dark)
            .statusBarHidden()
            .task { await camera.configure() }
            .onDisappear { camera.stop() }
            .sensoryFeedback(.impact(weight: .medium), trigger: model.captureFeedbackTrigger)
            .sensoryFeedback(.success, trigger: model.resultFeedbackTrigger)
            .sensoryFeedback(.impact(weight: .medium), trigger: pfandModel.captureFeedbackTrigger)
            .sensoryFeedback(.success, trigger: pfandModel.resultFeedbackTrigger)
            .animation(.easeInOut(duration: 0.25), value: activeErrorMessage)
            .onChange(of: appMode) { _, newMode in
                if newMode == .trashSorting { pfandModel.reset() }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { appMode = .trashSorting } label: {
                        Image(systemName: "trash.fill")
                            .frame(width: 28, height: 28)
                    }
                    .foregroundStyle(appMode == .trashSorting ? .primary : .tertiary)
                    .accessibilityLabel("Abfall sortieren")

                    Button { appMode = .pfandClassifier } label: {
                        Image(systemName: "waterbottle.fill")
                            .frame(width: 28, height: 28)
                    }
                    .foregroundStyle(appMode == .pfandClassifier ? .primary : .tertiary)
                    .accessibilityLabel("Pfand erkennen")
                }

                ToolbarSpacer(.fixed, placement: .primaryAction)

                ToolbarItem(placement: .primaryAction) {
                    Button { cycleFlashMode() } label: {
                        Image(systemName: flashSymbol)
                            .frame(width: 28, height: 28)
                            .foregroundStyle(camera.flashMode == .on ? .yellow : .primary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel("Blitz: \(flashAccessibilityValue)")
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
    }

    // MARK: - Computed helpers

    private var dimOpacity: Double {
        switch appMode {
        case .trashSorting:    model.phase == .idle ? 0 : 0.55
        case .pfandClassifier: pfandModel.isProcessing ? 0.55 : 0
        }
    }

    private var shutterVisible: Bool {
        switch appMode {
        case .trashSorting:    model.phase == .idle
        case .pfandClassifier: pfandModel.canCapture
        }
    }

    private var activeErrorMessage: String? {
        switch appMode {
        case .trashSorting:    model.errorMessage
        case .pfandClassifier: pfandModel.errorMessage
        }
    }

    // MARK: - Capture / result overlay (trash mode)

    @ViewBuilder
    private var captureOverlay: some View {
        if let image = model.capturedImage {
            VStack(spacing: 18) {
                capturedImageCard(image)

                if model.phase == .result, let result = model.result {
                    ResultCard(result: result, bounceTrigger: model.resultFeedbackTrigger)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 32)
            .transition(.scale(scale: 0.3, anchor: .center).combined(with: .opacity))
        }
    }

    private func capturedImageCard(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 260, height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                if model.phase == .processing {
                    ShimmerOverlay()
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
    }

    // MARK: - Controls

    private var controlsOverlay: some View {
        VStack {
            Spacer()

            if zoomPresets.count > 1 {
                ZoomControl(current: camera.zoomFactor, presets: zoomPresets) { preset in
                    setZoom(to: preset)
                }
                .padding(.bottom, 18)
            }

            HStack {
                Spacer()
                ShutterButton(isEnabled: shutterVisible) {
                    triggerCapture()
                }
                Spacer()
            }
            .overlay(alignment: .trailing) {
                switchCameraButton
                    .padding(.trailing, 36)
            }
            .padding(.bottom, 24)
        }
        .padding(.vertical, 12)
        .opacity(shutterVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: shutterVisible)
    }

    private var switchCameraButton: some View {
        Button {
            withAnimation(.snappy) { camera.switchCamera() }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                .font(.title2)
                .padding(10)
        }
        .accessibilityLabel("Kamera wechseln")
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }

    private func errorToast(_ message: String) -> some View {
        VStack {
            Spacer()
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 140)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .allowsHitTesting(false)
    }

    // MARK: - Actions

    private func triggerCapture() {
        guard shutterVisible else { return }

        withAnimation(.easeOut(duration: 0.08)) { shutterFlash = true }
        Task {
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.easeIn(duration: 0.25)) { shutterFlash = false }
        }

        switch appMode {
        case .trashSorting:
            Task { await model.capture(using: camera) }
        case .pfandClassifier:
            pfandModel.onShutter(using: camera)
        }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                camera.setZoom(baseZoom * value.magnification)
            }
            .onEnded { _ in
                baseZoom = camera.zoomFactor
            }
    }

    private var zoomPresets: [CGFloat] {
        [1, 2, 4].filter { $0 <= camera.maxZoomFactor }
    }

    private func setZoom(to factor: CGFloat) {
        withAnimation(.snappy) { camera.setZoom(factor) }
        baseZoom = factor
    }

    private func cycleFlashMode() {
        withAnimation(.snappy) {
            camera.flashMode = switch camera.flashMode {
            case .off: .auto
            case .auto: .on
            default: .off
            }
        }
    }

    private var flashSymbol: String {
        switch camera.flashMode {
        case .off:  "bolt.slash.fill"
        case .auto: "bolt.badge.automatic.fill"
        default:    "bolt.fill"
        }
    }

    private var flashAccessibilityValue: String {
        switch camera.flashMode {
        case .off:  "Aus"
        case .auto: "Automatisch"
        default:    "An"
        }
    }
}

// MARK: - Shutter button

private struct ShutterButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 78, height: 78)
                Circle()
                    .fill(.white)
                    .frame(width: 62, height: 62)
            }
        }
        .buttonStyle(ShutterButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel("Aufnehmen")
    }

    private struct ShutterButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
        }
    }
}

// MARK: - Zoom control

/// A segmented zoom-preset picker. The current-value label tracks the live zoom
/// (e.g. "1.5×") when the user pinch-zooms between presets.
private struct ZoomControl: View {
    let current: CGFloat
    let presets: [CGFloat]
    let onSelect: (CGFloat) -> Void

    var body: some View {
        Picker(
            selection: Binding(get: { activePreset }, set: { onSelect($0) })
        ) {
            ForEach(presets, id: \.self) { preset in
                Text("\(Int(preset))×").tag(preset)
            }
        } label: {
            Text("Zoom")
        } currentValueLabel: {
            Text(currentZoomLabel)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 160)
        .animation(.snappy, value: current)
    }

    private var activePreset: CGFloat {
        presets.last(where: { current >= $0 - 0.05 }) ?? presets.first ?? 1
    }

    private var currentZoomLabel: String {
        let rounded = (current * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? "\(Int(rounded))×"
            : String(format: "%.1f×", rounded)
    }
}

// MARK: - Processing shimmer

/// A light streak that sweeps across an image while inference runs.
struct ShimmerOverlay: View {
    var cornerRadius: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            PhaseAnimator([-1.0, 1.0]) { phase in
                LinearGradient(
                    colors: [.clear, .white.opacity(0.65), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: width * 0.55)
                .offset(x: phase * width)
            } animation: { _ in
                .linear(duration: 1.1)
            }
        }
        .blendMode(.plusLighter)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
    }
}

// MARK: - Result card

private struct ResultCard: View {
    let result: Classification
    let bounceTrigger: Int

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: result.category.symbolName)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(result.category.tint)
                .symbolEffect(.bounce, value: bounceTrigger)
                .frame(width: 56, height: 56)
                .background(result.category.tint.opacity(0.18), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(result.category.displayName)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text(result.category.hint)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer(minLength: 8)

            Text(result.confidence, format: .percent.precision(.fractionLength(0)))
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(result.category.tint)
                .contentTransition(.numericText())
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(result.category.tint.opacity(0.45), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

// MARK: - Camera unavailable fallback

private struct CameraUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Kamerazugriff benötigt", systemImage: "camera.fill")
        } description: {
            Text("Erlaube den Kamerazugriff in den Einstellungen, um Abfall zu erkennen.")
        } actions: {
            Button("Einstellungen öffnen") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

#Preview {
    CameraView()
}
