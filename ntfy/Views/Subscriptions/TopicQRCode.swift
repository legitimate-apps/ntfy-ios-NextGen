import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// A topic's QR code holds its plain `https://<server>/<topic>` address. For ntfy-me.com the iPhone
/// Camera app opens that as a Universal Link; for any server, the Add sheet's scanner reads it back.
enum TopicQRCode {
    static func payload(baseUrl: String, topic: String) -> String? {
        guard var parts = URLComponents(string: baseUrl),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        // Append a path component, so topic text cannot become query/fragment metadata.
        if parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        guard let component = topic.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        parts.percentEncodedPath += "/" + component
        guard let address = parts.url?.absoluteString, let link = TopicLink(scanned: address),
              link.topic == topic else { return nil }
        return topicUrl(baseUrl: link.server, topic: link.topic)
    }

    /// Black modules on white with the standard four-module quiet zone, scaled by whole pixels so
    /// every module stays sharp. Medium error correction survives a scratched or dim screen.
    static func image(for payload: String, pixelsPerModule: CGFloat = 12) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let scaled = code.transformed(by: CGAffineTransform(scaleX: pixelsPerModule, y: pixelsPerModule))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct TopicQRCodeView: View {
    let baseUrl: String
    let topic: String
    @Binding var isShowing: Bool
    @State private var sharing = false

    private var payload: String? { TopicQRCode.payload(baseUrl: baseUrl, topic: topic) }
    private var shareItems: [Any] {
        guard let payload, let url = URL(string: payload), let image = TopicQRCode.image(for: payload) else { return [] }
        return [image, url]
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    if let payload, let image = TopicQRCode.image(for: payload) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 300)
                            .padding(12)
                            // Always dark on light: scanners misread an inverted code in dark mode.
                            .background(Color.white)
                            .cornerRadius(12)
                            .accessibilityLabel(String(localized: "QR code for \(shortUrl(url: payload))"))
                        Text(payload)
                            .font(.callout.monospaced())
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                        Label {
                            Text(String(localized: "Anyone who scans this code can subscribe to this topic and read its messages, unless the server requires a login. Share it only with people you trust."))
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.shield")
                        }
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    } else {
                        Label(String(localized: "A safe topic address could not be created. Check the server and topic settings."),
                              systemImage: "exclamationmark.triangle")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .navigationTitle(String(localized: "QR code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "Done")) { isShowing = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        sharing = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(String(localized: "Share"))
                    .disabled(shareItems.isEmpty)
                }
            }
            .sheet(isPresented: $sharing) {
                TopicQRShareSheet(items: shareItems)
            }
        }
    }
}

private struct TopicQRShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// What the scanner screen can show before it has a code.
enum TopicQRCameraState: Equatable {
    case scanning, needsPermission, denied, unavailable

    static func from(hasCamera: Bool, status: AVAuthorizationStatus) -> TopicQRCameraState {
        guard hasCamera else { return .unavailable }
        switch status {
        case .authorized: return .scanning
        case .notDetermined: return .needsPermission
        default: return .denied
        }
    }
}

/// Injectable camera authorization, shared by the scanner UI and lifecycle tests.
final class TopicQRAuthorization: ObservableObject {
    @Published private(set) var state: TopicQRCameraState
    private let hasCamera: () -> Bool
    private let status: () -> AVAuthorizationStatus
    private let requestAccess: (@escaping (Bool) -> Void) -> Void
    private let center: NotificationCenter
    private var activationObserver: NSObjectProtocol?
    private var requesting = false

    init(hasCamera: @escaping () -> Bool = { AVCaptureDevice.default(for: .video) != nil },
         status: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .video) },
         requestAccess: @escaping (@escaping (Bool) -> Void) -> Void = { AVCaptureDevice.requestAccess(for: .video, completionHandler: $0) },
         center: NotificationCenter = .default) {
        self.hasCamera = hasCamera
        self.status = status
        self.requestAccess = requestAccess
        self.center = center
        state = .from(hasCamera: hasCamera(), status: status())
        activationObserver = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            self?.appear()
        }
    }

    deinit {
        if let activationObserver { center.removeObserver(activationObserver) }
    }

    func appear() {
        state = .from(hasCamera: hasCamera(), status: status())
        if state == .needsPermission && !requesting {
            requesting = true
            requestAccess { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.requesting = false
                    self.state = .from(hasCamera: self.hasCamera(), status: self.status())
                }
            }
        }
    }
}

/// Serializes the blocking AVFoundation calls. Closures let tests observe real lifecycle decisions
/// without requiring camera hardware.
final class TopicQRCaptureLifecycle {
    private let queue: DispatchQueue
    private let start: () -> Void
    private let stop: () -> Void
    private let authorized: () -> Bool
    private let center: NotificationCenter
    private var observers = [NSObjectProtocol]()
    // These inputs and the blocking session calls all live on the same serial queue. A late
    // start cannot overtake a background/dismissal stop.
    private var active: Bool
    private var visible = false
    private var running = false

    init(queue: DispatchQueue, center: NotificationCenter = .default,
         isActive: Bool = UIApplication.shared.applicationState == .active,
         authorized: @escaping () -> Bool = { AVCaptureDevice.authorizationStatus(for: .video) == .authorized },
         start: @escaping () -> Void, stop: @escaping () -> Void) {
        self.queue = queue
        self.start = start
        self.stop = stop
        self.authorized = authorized
        self.center = center
        active = isActive
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.setActive(note.name == UIApplication.didBecomeActiveNotification)
            })
        }
    }

    deinit {
        observers.forEach(center.removeObserver)
        let stop = stop
        queue.async { stop() }
    }

    func appear() {
        queue.async { [self] in visible = true; update() }
    }

    func disappear() {
        queue.async { [self] in visible = false; update() }
    }

    private func setActive(_ value: Bool) {
        queue.async { [self] in active = value; update() }
    }

    private func update() {
        let shouldRun = active && visible && authorized()
        guard shouldRun != running else { return }
        running = shouldRun
        if shouldRun { start() } else { stop() }
    }
}

/// Reads one topic QR code. `onCode` gets every decoded string and returns whether it was a topic
/// address; the caller closes this screen when it was.
struct TopicQRScannerView: View {
    @Binding var isShowing: Bool
    let onCode: (String) -> Bool
    @StateObject private var camera: TopicQRAuthorization
    @State private var rejected: String?
    @State private var accepted = false

    init(isShowing: Binding<Bool>, onCode: @escaping (String) -> Bool,
         camera: TopicQRAuthorization? = nil) {
        _isShowing = isShowing
        self.onCode = onCode
        _camera = StateObject(wrappedValue: camera ?? TopicQRAuthorization())
    }

    var body: some View {
        NavigationView {
            content
                .navigationTitle(String(localized: "qr.scan.title", defaultValue: "Scan QR code"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(String(localized: "Cancel")) { isShowing = false }
                    }
                }
        }
        .onAppear {
            camera.appear()
            #if DEBUG
            // The simulator has no camera. This feeds a decoded string through the same path a real
            // scan takes, for UI checks only; release builds never read it.
            if let simulated = ProcessInfo.processInfo.environment["NTFY_SIMULATED_QR_SCAN"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { deliver(simulated) }
            }
            #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        switch camera.state {
        case .scanning:
            QRCaptureView(onCode: deliver)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    Text(rejected.map(Self.rejectionText) ?? String(localized: "Point the camera at a topic's QR code."))
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                }
        case .needsPermission:
            ProgressView()
                .accessibilityLabel(String(localized: "Requesting camera access"))
        case .denied:
            message(
                icon: "camera",
                text: String(localized: "NTFY me needs camera access to scan a QR code. You can allow it in Settings, or type the topic and server in instead."),
                action: (String(localized: "Open Settings"), {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }))
        case .unavailable:
            message(icon: "camera", text: String(localized: "This device has no camera. Type the topic and server in instead."),
                    action: nil)
        }
    }

    private func message(icon: String, text: String, action: (String, () -> Void)?) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                Text(text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.0, action: action.1)
                        .buttonStyle(.borderedProminent)
                }
                if let rejected {
                    Text(Self.rejectionText(rejected))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }

    /// Any code, including a web link, can carry secrets. Never echo rejected input.
    static func rejectionText(_ code: String) -> String {
        String(localized: "That code isn't an ntfy topic address.")
    }

    private func deliver(_ code: String) {
        // The camera reports the same code many times a second; act on each one once.
        guard !accepted, code != rejected else { return }
        if onCode(code) {
            accepted = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            isShowing = false
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            rejected = code
        }
    }
}

/// AVFoundation runs on every iOS 15 device; VisionKit's DataScannerViewController needs iOS 16 and an A12.
private struct QRCaptureView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(onCode: onCode)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onCode = onCode
    }

    final class Controller: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: (String) -> Void
        private let session = AVCaptureSession()
        private let preview: AVCaptureVideoPreviewLayer
        private lazy var lifecycle = TopicQRCaptureLifecycle(
            queue: DispatchQueue(label: "ntfy.qr.capture"),
            start: { [session] in session.startRunning() },
            stop: { [session] in session.stopRunning() })

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
            preview = AVCaptureVideoPreviewLayer(session: session)
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            let output = AVCaptureMetadataOutput()
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input), session.canAddOutput(output) else { return }
            session.addInput(input)
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            lifecycle.appear()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            lifecycle.disappear()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            for case let code as AVMetadataMachineReadableCodeObject in objects {
                if let value = code.stringValue { onCode(value) }
            }
        }
    }
}
