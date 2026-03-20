import SwiftUI
import AVFoundation

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showManualEntry = false
    @State private var manualPayload = ""
    @State private var hasScanned = false

    let onScan: (String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                // Camera preview
                CameraPreviewView(onCodeScanned: { code in
                    guard !hasScanned else { return }
                    hasScanned = true
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)
                    onScan(code)
                    dismiss()
                })
                .ignoresSafeArea()

                // Viewfinder overlay
                ViewfinderOverlay()

                // Bottom controls
                VStack {
                    Spacer()

                    if showManualEntry {
                        VStack(spacing: 12) {
                            TextField("Paste QR payload", text: $manualPayload, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .lineLimit(3...6)

                            Button {
                                guard !manualPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                onScan(manualPayload)
                                dismiss()
                            } label: {
                                Text("Use Payload")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding()
                    } else {
                        Button {
                            withAnimation { showManualEntry = true }
                        } label: {
                            Label("Enter Manually", systemImage: "keyboard")
                                .font(.callout)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Camera Preview

private struct CameraPreviewView: UIViewRepresentable {
    let onCodeScanned: (String) -> Void

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.onCodeScanned = onCodeScanned
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {}
}

private final class CameraPreviewUIView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?
    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, previewLayer == nil else { return }
        setupCamera()
    }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            return
        }

        captureSession.addInput(input)

        let metadataOutput = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(metadataOutput) else { return }
        captureSession.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
        metadataOutput.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        self.layer.addSublayer(layer)
        previewLayer = layer

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        captureSession.stopRunning()
        onCodeScanned?(value)
    }
}

// MARK: - Viewfinder Overlay

private struct ViewfinderOverlay: View {
    @State private var animateScanner = false
    private let finderSize: CGFloat = 250

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            // Clear cutout
            RoundedRectangle(cornerRadius: 20)
                .frame(width: finderSize, height: finderSize)
                .blendMode(.destinationOut)

            // Corner brackets
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white, lineWidth: 3)
                .frame(width: finderSize, height: finderSize)

            // Scanning line
            Rectangle()
                .fill(LinearGradient(
                    colors: [.clear, .green.opacity(0.6), .clear],
                    startPoint: .leading, endPoint: .trailing
                ))
                .frame(width: finderSize - 20, height: 2)
                .offset(y: animateScanner ? finderSize / 2 - 20 : -(finderSize / 2 - 20))
                .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: animateScanner)

            // Instruction text
            VStack {
                Spacer()
                Text("Point camera at QR code")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.bottom, 120)
            }
        }
        .compositingGroup()
        .onAppear { animateScanner = true }
    }
}
