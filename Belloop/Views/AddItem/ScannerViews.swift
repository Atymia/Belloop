import SwiftUI
import Vision
import VisionKit
import UIKit
import AVFoundation

enum ScanHint { case idle, holdSteady, chooseOne }

// what a scan found
struct ScanResult: Equatable {
    var barcode: String?
    var date: Date?
}

// MARK: - Scanner
// looks for the barcode and the expiration date in the same session:
// you point at the barcode, turn the package, and the date gets read too (or the other
// way round). no need to cover the barcode anymore when the date is printed next to it
struct ScannerSheet: View {
    // when the camera is the first thing you see (Home's scan button) there's a way
    // out for products without a barcode, like Wallet's "Enter card details manually"
    var onManual: (() -> Void)? = nil
    let onFinish: (ScanResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var result = ScanResult()
    @State private var hint: ScanHint = .idle
    @State private var torchOn = false
    @State private var finished = false
    // after a few seconds without a date, the hint gives a tip
    @State private var showTip = false

    // false on the simulator and on devices without a flashlight
    private var hasTorch: Bool { AVCaptureDevice.default(for: .video)?.hasTorch ?? false }

    private var tip: LocalizedStringKey {
        "Can't find it? Move a little farther away so it's in focus, or turn on the flashlight."
    }

    private var hintText: LocalizedStringKey {
        switch hint {
        case .holdSteady: return "Date found — hold steady…"
        case .chooseOne:  return "Several dates found — tap the expiration date"
        case .idle: break
        }
        switch (result.barcode != nil, result.date != nil) {
        case (false, false):
            return "Point the camera at the barcode and the expiration date"
        case (true, false):
            return showTip ? tip : "Got the barcode. Now the expiration date, it's often on the top or on the back."
        case (false, true):
            return "Got the date. Now the barcode."
        case (true, true):
            return "Done"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerView.isSupported {
                    ZStack {
                        DataScannerView(
                            torchOn: torchOn,
                            onBarcode: { result.barcode = $0 },
                            onDate: { result.date = $0 },
                            onHint: { hint = $0 }
                        )
                        .ignoresSafeArea()

                        VStack(spacing: 12) {
                            // what's been found so far
                            progress
                            Spacer()
                            Text(hintText)
                                .font(.subheadline.bold())
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .modifier(HintBackground())
                                .padding(.horizontal)
                            if let onManual {
                                Button("Enter manually", action: onManual)
                                    .buttonStyle(.glass)
                                    .controlSize(.large)
                            }
                        }
                        .padding(.bottom, 24)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Scanner unavailable", systemImage: "camera.metering.unknown")
                    } description: {
                        Text("A real iPhone with camera access is required. You can enter the details by hand.")
                    } actions: {
                        if let onManual {
                            Button("Enter manually", action: onManual)
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .navigationTitle("Scan product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // X like every iOS 26 sheet. nothing gets saved: from the form you go back to it,
                // from Home's scan button the whole sheet closes
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
                // flashlight for bottles and dark packages
                if hasTorch {
                    ToolbarItem(placement: .topBarTrailing) {
                        // LocalizedStringKey so the title gets translated
                        Button(torchOn ? LocalizedStringKey("Turn Flashlight Off") : LocalizedStringKey("Turn Flashlight On"),
                               systemImage: torchOn ? "flashlight.on.fill" : "flashlight.off.fill") {
                            torchOn.toggle()
                        }
                    }
                }
                // the date isn't on the package or can't be read: keep what was found
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { finish() }
                        .disabled(result == ScanResult())
                }
            }
            // no date for 5 seconds: show the tip (any date found resets it)
            .task(id: hint) {
                showTip = false
                guard hint == .idle, result.date == nil else { return }
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { showTip = true }
            }
            // both found: a short pause so you see the two checkmarks, then on to the form
            .onChange(of: result) { _, found in
                guard found.barcode != nil, found.date != nil else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    finish()
                }
            }
        }
    }

    // two small labels at the top that tick when found
    private var progress: some View {
        HStack(spacing: 8) {
            step("Barcode", symbol: "barcode", done: result.barcode != nil)
            step("Expiration date", symbol: "calendar", done: result.date != nil)
        }
        .padding(.top, 12)
    }

    private func step(_ title: LocalizedStringKey, symbol: String, done: Bool) -> some View {
        Label(title, systemImage: done ? "checkmark.circle.fill" : symbol)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(done ? Color("StatusFresh") : .primary)
            .contentTransition(.symbolEffect(.replace))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .modifier(HintBackground())
            .accessibilityValue(done ? Text("Found") : Text("Not found yet"))
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish(result)
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
    var torchOn = false
    let onBarcode: (String) -> Void
    let onDate: (Date) -> Void
    let onHint: (ScanHint) -> Void

    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let barcodes: DataScannerViewController.RecognizedDataType =
            .barcode(symbologies: [.ean13, .ean8, .upce])

        // no default highlight, it would box every word.
        // I draw boxes only around dates.
        // high frame rate tracking is OFF: a date doesn't need fast tracking,
        // and the slower camera mode gets along better with the flashlight
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text(), barcodes],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: false,
            isHighlightingEnabled: false
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning {
            try? scanner.startScanning()
            // dates are tiny: with 2x zoom you hold the phone farther away, where the camera
            // can focus (up close the picture is blurry). barcodes read fine at 2x too
            scanner.zoomFactor = min(max(2, scanner.minZoomFactor), scanner.maxZoomFactor)
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
        private var barcodeSent = false
        private var dateSent = false

        private struct Candidate {
            let date: Date
            let day: Date
            let overlay: DateHighlightView
        }
        private var candidates: [UUID: Candidate] = [:]
        // where the bars are: text on top of them is ignored
        private var barcodeZones: [UUID: CGRect] = [:]
        // the barcode numbers seen so far: the digits printed under the bars are the same,
        // so a text made of those digits is never a date. Before, I ignored a big area around
        // the barcode instead, and a date printed right next to it was ignored too
        // (people had to cover the barcode with a finger)
        private var barcodeNumbers: Set<String> = []
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
            process(addedItems, in: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didUpdate updatedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            process(updatedItems, in: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didRemove removedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in removedItems {
                barcodeZones.removeValue(forKey: item.id)
                drop(item.id)
            }
            evaluate()
        }

        // MARK: Barcodes and dates
        private func process(_ items: [RecognizedItem], in scanner: DataScannerViewController) {
            // barcodes first so the texts can be checked against them
            for item in items {
                guard case .barcode(let code) = item else { continue }
                barcodeZones[item.id] = Self.rect(for: item.bounds).insetBy(dx: -4, dy: -4)
                guard let value = code.payloadStringValue else { continue }
                barcodeNumbers.insert(value)
                if !barcodeSent {
                    barcodeSent = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    parent.onBarcode(value)
                }
            }
            for (id, candidate) in candidates where barcodeZones.values.contains(where: { $0.intersects(candidate.overlay.frame) }) {
                drop(id)
            }
            guard !dateSent else { return }
            for item in items { if case .text = item { consider(item, in: scanner) } }
            evaluate()
        }

        // the line of digits under the bars ("8 001234 567890"), or a piece of it
        private func isBarcodeNumber(_ text: String) -> Bool {
            let digits = text.filter(\.isNumber)
            guard digits.count >= 6 else { return false }
            return barcodeNumbers.contains { $0.contains(digits) || digits.contains($0) }
        }

        private func consider(_ item: RecognizedItem, in scanner: DataScannerViewController) {
            guard case .text(let text) = item else { return }
            let rect = Self.rect(for: item.bounds)
            guard !barcodeZones.values.contains(where: { $0.intersects(rect) }),
                  !isBarcodeNumber(text.transcript),
                  let date = DateParser.parse(text.transcript) else {
                drop(item.id)   // not a date (anymore), remove the box
                return
            }
            let frame = rect.insetBy(dx: -6, dy: -4)
            let day = Calendar.current.startOfDay(for: date)

            if let existing = candidates[item.id] {
                existing.overlay.frame = frame
                existing.overlay.accessibilityValue = text.transcript
                candidates[item.id] = Candidate(date: date, day: day, overlay: existing.overlay)
            } else {
                let overlay = DateHighlightView(frame: frame)
                // VoiceOver reads it as a button
                overlay.isAccessibilityElement = true
                overlay.accessibilityTraits = .button
                overlay.accessibilityLabel = String(localized: "Expiration date found")
                overlay.accessibilityValue = text.transcript
                overlay.onTap = { [weak self] in
                    if let candidate = self?.candidates[item.id] { self?.sendDate(candidate.date) }
                }
                scanner.overlayContainerView.addSubview(overlay)
                candidates[item.id] = Candidate(date: date, day: day, overlay: overlay)
            }
        }

        private func drop(_ id: UUID) {
            candidates.removeValue(forKey: id)?.overlay.removeFromSuperview()
        }

        // one date: confirm automatically after ~1 second.
        // more dates: the user taps the right one
        private func evaluate() {
            guard !dateSent else { return }
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
                          let date = self.candidates.values.first?.date else { return }
                    self.sendDate(date)
                }
            default:
                parent.onHint(.chooseOne)
            }
        }

        private func sendDate(_ date: Date) {
            guard !dateSent else { return }
            dateSent = true
            lockTask?.cancel()
            for id in Array(candidates.keys) { drop(id) }   // the boxes did their job
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            parent.onHint(.idle)
            parent.onDate(date)
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
