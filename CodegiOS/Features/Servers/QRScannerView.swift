import SwiftUI
import AVFoundation
import UIKit

/// Full-screen QR scanner used to fill the Server URL when adding/editing a
/// server. Mirrors `CameraPicker`'s representable pattern (AttachmentPickers.swift)
/// but uses a live `AVCaptureSession` + metadata output, since
/// `UIImagePickerController` can't scan codes. Calls `onScan` once with the
/// decoded string, then dismisses itself.
///
/// The caller parses both legacy server URLs and pairing JSON, including the
/// optional token and certificate fingerprint. Capture stays payload-agnostic.
struct QRScannerView: View {
    var onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var torchOn = false
    @State private var didScan = false

    /// No capture device on the Simulator (or a camera-less device).
    private var cameraAvailable: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }

    private var isScanning: Bool {
        cameraAvailable && authorization == .authorized
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isScanning {
                ScannerPreview(torchOn: $torchOn, onScan: handleScan)
                    .ignoresSafeArea()
                ScanReticleMask().ignoresSafeArea()
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                centerContent
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .preferredColorScheme(.dark)
        .task { await requestIfNeeded() }
    }

    // MARK: - Bars & states

    private var topBar: some View {
        HStack {
            circleButton(systemName: "xmark") { dismiss() }
                .accessibilityLabel("Cancel")

            Spacer()
            Text("Scan Server QR")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()

            if isScanning {
                circleButton(systemName: torchOn ? "bolt.fill" : "bolt.slash.fill",
                             tint: torchOn ? .yellow : .white) {
                    torchOn.toggle()
                }
                .accessibilityLabel(torchOn ? "Turn off flashlight" : "Turn on flashlight")
            } else {
                // Keep the title centered.
                Color.clear.frame(width: 40, height: 40)
            }
        }
    }

    @ViewBuilder
    private var centerContent: some View {
        if !cameraAvailable {
            stateMessage(
                icon: "video.slash",
                title: "Camera Unavailable",
                message: "This device has no camera, so QR scanning isn't available here. Enter the server URL manually."
            )
        } else {
            switch authorization {
            case .authorized:
                VStack(spacing: 18) {
                    ScanReticle()
                    Text("Align your codeg server's QR code within the frame.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                }
            case .notDetermined:
                ProgressView().tint(.white)
            default:
                VStack(spacing: 16) {
                    stateMessage(
                        icon: "lock.fill",
                        title: "Camera Access Needed",
                        message: "Allow camera access to scan a server's QR code."
                    )
                    Button { openSettings() } label: {
                        Text("Open Settings").fontWeight(.semibold).padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                }
            }
        }
    }

    private func stateMessage(icon: String, title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.85))
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
    }

    private func circleButton(systemName: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.4), in: Circle())
        }
    }

    // MARK: - Actions

    private func handleScan(_ code: String) {
        guard !didScan else { return }
        didScan = true
        onScan(code)
        dismiss()
    }

    private func requestIfNeeded() async {
        guard cameraAvailable, authorization == .notDetermined else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        authorization = granted ? .authorized : .denied
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Reticle

/// A rounded square outline marking the scan target area.
private struct ScanReticle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .stroke(.white.opacity(0.92), lineWidth: 3)
            .frame(width: 232, height: 232)
            .shadow(color: .black.opacity(0.45), radius: 8)
    }
}

/// A dimming scrim with a clear cut-out window over the live preview, so the
/// camera shows through only inside the reticle.
private struct ScanReticleMask: View {
    var body: some View {
        GeometryReader { _ in
            Color.black.opacity(0.4)
                .mask {
                    Rectangle()
                        .overlay(alignment: .center) {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .frame(width: 232, height: 232)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Capture wrapper

/// SwiftUI wrapper over an `AVCaptureSession`-backed view controller that scans
/// QR codes and reports the first decoded value.
private struct ScannerPreview: UIViewControllerRepresentable {
    @Binding var torchOn: Bool
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {
        controller.setTorch(torchOn)
    }
}

/// Owns the capture session lifecycle: starts on appear, stops on disappear, and
/// emits the first decoded QR string exactly once.
final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.codeg.ios.qrscanner.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureDevice: AVCaptureDevice?
    private var configured = false
    private var didEmit = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stop()
    }

    private func configureSession() {
        guard !configured else { return }
        configured = true

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        captureDevice = device
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
    }

    private func start() {
        sessionQueue.async { [session] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    private func stop() {
        sessionQueue.async { [session] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    /// Toggle the back-camera torch (no-op if the device lacks one).
    func setTorch(_ on: Bool) {
        guard let device = captureDevice, device.hasTorch else { return }
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didEmit,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue, !value.isEmpty else { return }
        didEmit = true
        stop()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScan?(value)
    }
}
