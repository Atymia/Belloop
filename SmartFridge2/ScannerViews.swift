import SwiftUI
import Vision
import VisionKit
import UIKit
import AVFoundation

enum ScanHint { case idle, holdSteady, chooseOne }

// MARK: - Scanner (barcode or date)
struct ScannerSheet: View {
    enum Mode { case barcode, text }

    let mode: Mode
    let onResult: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hint: ScanHint = .idle
    @State private var torchOn = false
    // after a few seconds without a date, the hint gives a tip
    @State private var showTip = false

    // false on the simulator and on devices without a flashlight
    private var hasTorch: Bool { AVCaptureDevice.default(for: .video)?.hasTorch ?? false }

    private var title: LocalizedStringKey { mode == .barcode ? "Barcode" : "Expiration date" }

    private var hintText: LocalizedStringKey {
        switch (mode, hint) {
        case (.barcode, _):          "Point the camera at the barcode"
        case (.text, .idle):
            showTip ? "Can't find it? Move a little farther away so it's in focus, or turn on the flashlight."
                    : "Point the camera at the date. On bottles, tilt them to avoid reflections."
        case (.text, .holdSteady):   "Date found — hold steady…"
        case (.text, .chooseOne):    "Several dates found — tap the expiration date"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerView.isSupported {
                    ZStack(alignment: .bottom) {
                        DataScannerView(mode: mode, torchOn: torchOn, onResult: onResult, onHint: { hint = $0 })
                            .ignoresSafeArea()

                        Text(hintText)
                            .font(.subheadline.bold())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .modifier(HintBackground())
                            .padding(.bottom, 30)
                    }
                } else {
                    ContentUnavailableView(
                        "Scanner unavailable",
                        systemImage: "camera.metering.unknown",
                        description: Text("A real iPhone with camera access is required. You can enter the details by hand.")
                    )
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                // flashlight for bottles and dark packages
                if mode == .text, hasTorch {
                    ToolbarItem(placement: .topBarTrailing) {
                        // LocalizedStringKey so the title gets translated
                        Button(torchOn ? LocalizedStringKey("Turn Flashlight Off") : LocalizedStringKey("Turn Flashlight On"),
                               systemImage: torchOn ? "flashlight.on.fill" : "flashlight.off.fill") {
                            torchOn.toggle()
                        }
                    }
                }
            }
            // no date for 5 seconds: show the tip (any date found resets it)
            .task(id: hint) {
                showTip = false
                guard mode == .text, hint == .idle else { return }
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { showTip = true }
            }
        }
    }
}

// MARK: - Hint background (solid if Reduce Transparency is on)
private struct HintBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(.regularMaterial, in: .capsule)
        } else {
            content.glassEffect(.regular, in: .capsule)
        }
    }
}

// MARK: - Green box around dates
final class DateHighlightView: UIView {
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 8
        layer.borderWidth = 3
        layer.borderColor = UIColor.systemGreen.cgColor
        backgroundColor = UIColor.systemGreen.withAlphaComponent(0.15)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func tapped() { onTap?() }
}

// MARK: - DataScanner
struct DataScannerView: UIViewControllerRepresentable {
    let mode: ScannerSheet.Mode
    var torchOn = false
    let onResult: (String) -> Void
    let onHint: (ScanHint) -> Void

    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let barcodes: DataScannerViewController.RecognizedDataType =
            .barcode(symbologies: [.ean13, .ean8, .upce])
        // also look for barcodes so their numbers aren't read as dates
        let types: Set<DataScannerViewController.RecognizedDataType> =
            mode == .barcode ? [barcodes] : [.text(), barcodes]

        // no default highlight, it would box every word.
        // I draw boxes only around dates.
        // high frame rate tracking is OFF: a date doesn't need fast tracking,
        // and the slower camera mode gets along better with the flashlight
        let scanner = DataScannerViewController(
            recognizedDataTypes: types,
            qualityLevel: .accurate,
            recognizesMultipleItems: mode == .text,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: mode == .barcode,
            isHighlightingEnabled: mode == .barcode
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning {
            try? scanner.startScanning()
            // dates are tiny: with 2x zoom you hold the phone farther away, where the camera
            // can focus (up close the picture is blurry, that's why only the flashlight helped)
            if mode == .text {
                scanner.zoomFactor = min(max(2, scanner.minZoomFactor), scanner.maxZoomFactor)
            }
        }
        context.coordinator.setTorch(torchOn)
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.setTorch(false)
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let parent: DataScannerView
        private var delivered = false

        private struct Candidate {
            let text: String
            let day: Date
            let overlay: DateHighlightView
        }
        private var candidates: [UUID: Candidate] = [:]
        // barcode areas, text inside is ignored
        private var barcodeZones: [UUID: CGRect] = [:]
        private var lockedDays: Set<Date> = []
        private var lockTask: Task<Void, Never>?

        init(_ parent: DataScannerView) { self.parent = parent }

        // MARK: Flashlight
        // Known iPhone problem: the scanner runs on the "virtual" camera (the one that switches
        // between wide / ultra wide / tele). Turning the light on through a single physical camera
        // froze the preview. So we ask for the same virtual camera the scanner is using.
        private var torchApplied = false

        private static var scannerCamera: AVCaptureDevice? {
            let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera,
                                                        .builtInDualCamera, .builtInWideAngleCamera]
            for type in types {
                if let device = AVCaptureDevice.default(type, for: .video, position: .back), device.hasTorch {
                    return device
                }
            }
            return nil
        }

        func setTorch(_ on: Bool) {
            guard on != torchApplied,
                  let device = Self.scannerCamera, device.isTorchAvailable,
                  (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            if on {
                try? device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else {
                device.torchMode = .off
            }
            torchApplied = on
        }

        // MARK: Delegate
        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            switch parent.mode {
            case .barcode:
                for case .barcode(let code) in addedItems {
                    if let value = code.payloadStringValue { deliver(value); return }
                }
            case .text:
                process(addedItems, in: dataScanner)
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didUpdate updatedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard parent.mode == .text else { return }
            process(updatedItems, in: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didRemove removedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard parent.mode == .text else { return }
            for item in removedItems {
                barcodeZones.removeValue(forKey: item.id)
                drop(item.id)
            }
            evaluate()
        }

        // MARK: Dates
        private func process(_ items: [RecognizedItem], in scanner: DataScannerViewController) {
            // barcodes first so the texts can be checked against them
            for item in items { if case .barcode = item { markBarcodeZone(item) } }
            for item in items { if case .text = item { consider(item, in: scanner) } }
            evaluate()
        }

        private func markBarcodeZone(_ item: RecognizedItem) {
            // extra space below for the numbers under the bars
            let zone = Self.rect(for: item.bounds).insetBy(dx: -24, dy: -70)
            barcodeZones[item.id] = zone
            for (id, candidate) in candidates where candidate.overlay.frame.intersects(zone) {
                drop(id)
            }
        }

        private func consider(_ item: RecognizedItem, in scanner: DataScannerViewController) {
            guard case .text(let text) = item else { return }
            let rect = Self.rect(for: item.bounds)
            guard !barcodeZones.values.contains(where: { $0.intersects(rect) }),
                  let date = DateParser.parse(text.transcript) else {
                drop(item.id)   // not a date anymore, remove the box
                return
            }
            let frame = rect.insetBy(dx: -6, dy: -4)
            let day = Calendar.current.startOfDay(for: date)

            if let existing = candidates[item.id] {
                existing.overlay.frame = frame
                existing.overlay.accessibilityValue = text.transcript
                candidates[item.id] = Candidate(text: text.transcript, day: day, overlay: existing.overlay)
            } else {
                let overlay = DateHighlightView(frame: frame)
                // VoiceOver reads it as a button
                overlay.isAccessibilityElement = true
                overlay.accessibilityTraits = .button
                overlay.accessibilityLabel = String(localized: "Expiration date found")
                overlay.accessibilityValue = text.transcript
                overlay.onTap = { [weak self] in
                    if let candidate = self?.candidates[item.id] { self?.deliver(candidate.text) }
                }
                scanner.overlayContainerView.addSubview(overlay)
                candidates[item.id] = Candidate(text: text.transcript, day: day, overlay: overlay)
            }
        }

        private func drop(_ id: UUID) {
            candidates.removeValue(forKey: id)?.overlay.removeFromSuperview()
        }

        // one date: confirm automatically after ~1 second.
        // more dates: the user taps the right one
        private func evaluate() {
            let days = Set(candidates.values.map(\.day))
            guard days != lockedDays else { return }   // small movements don't reset the timer
            lockedDays = days
            lockTask?.cancel()

            switch days.count {
            case 0:
                parent.onHint(.idle)
            case 1:
                parent.onHint(.holdSteady)
                lockTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(900))
                    guard !Task.isCancelled, let self,
                          let text = self.candidates.values.first?.text else { return }
                    self.deliver(text)
                }
            default:
                parent.onHint(.chooseOne)
            }
        }

        private func deliver(_ value: String) {
            guard !delivered else { return }
            delivered = true
            lockTask?.cancel()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            parent.onResult(value)
        }

        private static func rect(for b: RecognizedItem.Bounds) -> CGRect {
            let xs = [b.topLeft.x, b.topRight.x, b.bottomLeft.x, b.bottomRight.x]
            let ys = [b.topLeft.y, b.topRight.y, b.bottomLeft.y, b.bottomRight.y]
            let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
            let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }
}

// MARK: - Camera for the photo
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
