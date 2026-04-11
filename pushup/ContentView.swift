//
//  ContentView.swift
//  pushup
//
//  Created by Victor Deleeck on 11/04/2026.
//

import AVFoundation
import SwiftUI
import UIKit
import Vision

struct SupportedApp: Identifiable, Hashable {
    let name: String
    let icon: String

    var id: String { name }

    static let defaults: [SupportedApp] = [
        SupportedApp(name: "TikTok", icon: "music.note.tv"),
        SupportedApp(name: "Instagram", icon: "camera"),
        SupportedApp(name: "YouTube", icon: "play.rectangle"),
        SupportedApp(name: "X", icon: "bubble.left.and.text.bubble.right"),
        SupportedApp(name: "Reddit", icon: "text.bubble")
    ]
}

struct TimeBank {
    let pushupCount: Int
    let minutesPerPushup: Int
    let usedMinutes: Int

    var earnedMinutes: Int {
        pushupCount * minutesPerPushup
    }

    var remainingMinutes: Int {
        max(earnedMinutes - usedMinutes, 0)
    }
}

enum CameraAccessState {
    case idle
    case requesting
    case granted
    case denied
    case unavailable
    case failed
}

struct PushupDetectorUpdate {
    let statusText: String
    let progress: CGFloat
    let didCompleteRep: Bool
    let faceDetected: Bool
}

struct PushupRepDetector {
    enum Phase {
        case calibrating
        case ready
        case lowered
    }

    private(set) var baselineArea: CGFloat?
    private(set) var phase: Phase = .calibrating
    private(set) var calibrationSamples = 0
    private(set) var smoothedArea: CGFloat?

    private let smoothingFactor: CGFloat = 0.18
    private let calibrationTarget = 12
    private let lowerThreshold: CGFloat = 1.33
    private let riseThreshold: CGFloat = 1.12

    mutating func process(faceArea: CGFloat?) -> PushupDetectorUpdate {
        guard let faceArea, faceArea > 0 else {
            phase = .calibrating
            calibrationSamples = 0
            baselineArea = nil
            smoothedArea = nil
            return PushupDetectorUpdate(
                statusText: "Move your face into the frame.",
                progress: 0,
                didCompleteRep: false,
                faceDetected: false
            )
        }

        let filteredArea: CGFloat
        if let smoothedArea {
            filteredArea = (smoothedArea * (1 - smoothingFactor)) + (faceArea * smoothingFactor)
        } else {
            filteredArea = faceArea
        }
        smoothedArea = filteredArea

        switch phase {
        case .calibrating:
            if let baselineArea {
                self.baselineArea = (baselineArea * 0.82) + (filteredArea * 0.18)
            } else {
                baselineArea = filteredArea
            }
            calibrationSamples += 1

            return PushupDetectorUpdate(
                statusText: calibrationSamples >= calibrationTarget ? "Start your rep." : "Hold the top position to calibrate.",
                progress: 0,
                didCompleteRep: false,
                faceDetected: true
            )

        case .ready:
            guard let baselineArea else {
                phase = .calibrating
                calibrationSamples = 0
                return PushupDetectorUpdate(
                    statusText: "Recalibrating...",
                    progress: 0,
                    didCompleteRep: false,
                    faceDetected: true
                )
            }

            if filteredArea < baselineArea * 1.05 {
                self.baselineArea = (baselineArea * 0.94) + (filteredArea * 0.06)
            }

            let ratio = filteredArea / max(baselineArea, 0.0001)
            let progress = min(max((ratio - 1) / (lowerThreshold - 1), 0), 1)

            if ratio >= lowerThreshold {
                phase = .lowered
                return PushupDetectorUpdate(
                    statusText: "Push back up.",
                    progress: 1,
                    didCompleteRep: false,
                    faceDetected: true
                )
            }

            return PushupDetectorUpdate(
                statusText: "Lower down until your face gets closer to the phone.",
                progress: progress,
                didCompleteRep: false,
                faceDetected: true
            )

        case .lowered:
            guard let baselineArea else {
                phase = .calibrating
                calibrationSamples = 0
                return PushupDetectorUpdate(
                    statusText: "Recalibrating...",
                    progress: 0,
                    didCompleteRep: false,
                    faceDetected: true
                )
            }

            let ratio = filteredArea / max(baselineArea, 0.0001)
            if ratio <= riseThreshold {
                phase = .ready
                self.baselineArea = filteredArea
                return PushupDetectorUpdate(
                    statusText: "Rep counted.",
                    progress: 0,
                    didCompleteRep: true,
                    faceDetected: true
                )
            }

            return PushupDetectorUpdate(
                statusText: "Push higher to finish the rep.",
                progress: 1,
                didCompleteRep: false,
                faceDetected: true
            )
        }
    }

    mutating func advanceCalibrationIfNeeded() {
        if phase == .calibrating, calibrationSamples >= calibrationTarget {
            phase = .ready
        }
    }
}

final class PushupCameraModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var accessState: CameraAccessState = .idle
    @Published private(set) var statusText = "Camera not started."
    @Published private(set) var repProgress: CGFloat = 0
    @Published private(set) var sessionRunning = false
    @Published private(set) var faceDetected = false

    let session = AVCaptureSession()

    var onRepCounted: (() -> Void)?

    private let sessionQueue = DispatchQueue(label: "pushup.camera.session")
    private var isConfigured = false
    private var detector = PushupRepDetector()
    private var processedFrameCount = 0

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            accessState = .granted
            configureAndStartIfNeeded()
        case .notDetermined:
            accessState = .requesting
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.accessState = granted ? .granted : .denied
                    if granted {
                        self.configureAndStartIfNeeded()
                    } else {
                        self.statusText = "Camera permission is required to count pushups."
                    }
                }
            }
        case .denied, .restricted:
            accessState = .denied
            statusText = "Enable camera access in Settings to track real reps."
        @unknown default:
            accessState = .failed
            statusText = "Camera authorization returned an unknown state."
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.sessionRunning = false
            }
        }
    }

    private func configureAndStartIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.prepareSessionIfNeeded() else { return }

            if !self.session.isRunning {
                self.session.startRunning()
            }

            DispatchQueue.main.async {
                self.sessionRunning = true
                self.statusText = "Hold the top of your pushup to calibrate."
            }
        }
    }

    private func prepareSessionIfNeeded() -> Bool {
        if isConfigured {
            return true
        }

        session.beginConfiguration()
        session.sessionPreset = .medium

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.accessState = .unavailable
                self.statusText = "No front camera is available on this device."
            }
            return false
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                DispatchQueue.main.async {
                    self.accessState = .failed
                    self.statusText = "Unable to configure the camera input."
                }
                return false
            }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.accessState = .failed
                self.statusText = "Unable to access the front camera."
            }
            return false
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: sessionQueue)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.accessState = .failed
                self.statusText = "Unable to read camera frames."
            }
            return false
        }
        session.addOutput(output)

        session.commitConfiguration()
        isConfigured = true
        return true
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        processedFrameCount += 1
        guard processedFrameCount.isMultiple(of: 3) else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .leftMirrored,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            DispatchQueue.main.async {
                self.statusText = "Face detection failed."
            }
            return
        }

        let faceArea = (request.results ?? [])
            .map(\.boundingBox)
            .map { $0.width * $0.height }
            .max()

        var update = detector.process(faceArea: faceArea)
        detector.advanceCalibrationIfNeeded()
        if detector.phase == .ready, update.statusText == "Start your rep." {
            update = PushupDetectorUpdate(
                statusText: "Lower down until your face gets closer to the phone.",
                progress: 0,
                didCompleteRep: false,
                faceDetected: true
            )
        }

        DispatchQueue.main.async {
            self.faceDetected = update.faceDetected
            self.repProgress = update.progress
            self.statusText = update.statusText

            if update.didCompleteRep {
                self.onRepCounted?()
            }
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("Expected AVCaptureVideoPreviewLayer")
        }
        return layer
    }
}

struct ContentView: View {
    @AppStorage("pushupCount") private var pushupCount = 0
    @AppStorage("minutesPerPushup") private var minutesPerPushup = 5
    @AppStorage("usedMinutes") private var usedMinutes = 0
    @AppStorage("selectedApps") private var selectedAppsStorage = "TikTok,Instagram"

    @StateObject private var cameraModel = PushupCameraModel()

    private let supportedApps = SupportedApp.defaults

    private var bank: TimeBank {
        TimeBank(
            pushupCount: pushupCount,
            minutesPerPushup: minutesPerPushup,
            usedMinutes: usedMinutes
        )
    }

    private var selectedApps: Set<String> {
        Set(
            selectedAppsStorage
                .split(separator: ",")
                .map { String($0) }
        )
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.97, green: 0.54, blue: 0.25),
                    Color(red: 0.70, green: 0.18, blue: 0.12),
                    Color.black.opacity(0.92)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    balanceCard
                    cameraCard
                    selectedAppsCard
                    rulesCard
                }
                .padding(20)
            }
        }
        .onAppear {
            cameraModel.onRepCounted = {
                pushupCount += 1
            }
            cameraModel.start()
        }
        .onDisappear {
            cameraModel.stop()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Earn your scroll")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(.white)

            Text("Real reps only. The front camera watches how close you come to the phone and counts a pushup after a full down-and-up motion.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Time Bank")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(bank.remainingMinutes)")
                    .font(.system(size: 54, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text("minutes left")
                    .font(.system(.title3, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }

            HStack(spacing: 12) {
                statPill(title: "Pushups", value: "\(pushupCount)")
                statPill(title: "Earned", value: "\(bank.earnedMinutes)m")
                statPill(title: "Used", value: "\(usedMinutes)m")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rep Tracker")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.white)

            cameraSurface

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle()
                        .fill(cameraModel.faceDetected ? Color.green : Color.white.opacity(0.35))
                        .frame(width: 10, height: 10)
                    Text(cameraModel.statusText)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white.opacity(0.86))
                }

                ProgressView(value: cameraModel.repProgress)
                    .tint(.white)

                HStack(spacing: 12) {
                    quickButton(title: "Use 5 min", isPrimary: false) {
                        usedMinutes = min(bank.earnedMinutes, usedMinutes + 5)
                    }

                    quickButton(title: "Reset day", isPrimary: false) {
                        pushupCount = 0
                        usedMinutes = 0
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    @ViewBuilder
    private var cameraSurface: some View {
        switch cameraModel.accessState {
        case .granted, .idle:
            CameraPreviewView(session: cameraModel.session)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text(cameraModel.sessionRunning ? "LIVE" : "STARTING")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55))
                        .clipShape(Capsule())
                        .padding(14)
                }

        case .requesting:
            cameraPlaceholder(text: "Requesting camera access...")

        case .denied:
            cameraPlaceholder(text: "Camera access is off. Enable it in Settings.")

        case .unavailable:
            cameraPlaceholder(text: "This device does not have a usable front camera.")

        case .failed:
            cameraPlaceholder(text: "The camera session could not be started.")
        }
    }

    private var selectedAppsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Target Apps")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.white)

            Text("These are the apps you want to earn time for. The Screen Time enforcement layer still needs to be connected separately.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(supportedApps) { app in
                    Button {
                        toggleSelection(for: app.name)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: app.icon)
                                .frame(width: 28, height: 28)
                            Text(app.name)
                                .font(.system(.body, design: .rounded))
                                .fontWeight(.semibold)
                            Spacer(minLength: 0)
                            Image(systemName: selectedApps.contains(app.name) ? "checkmark.circle.fill" : "circle")
                        }
                        .foregroundStyle(.white)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectedApps.contains(app.name) ? Color.white.opacity(0.20) : Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rules")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Minutes per pushup")
                    Spacer()
                    Stepper("\(minutesPerPushup)", value: $minutesPerPushup, in: 1...20)
                        .labelsHidden()
                    Text("\(minutesPerPushup)m")
                        .fontWeight(.bold)
                }

                HStack {
                    Text("Selected apps")
                    Spacer()
                    Text(selectedApps.isEmpty ? "None" : "\(selectedApps.count)")
                        .fontWeight(.bold)
                }
            }
            .font(.system(.body, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func statPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.heavy)
                .foregroundStyle(.white)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func quickButton(title: String, isPrimary: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.body, design: .rounded))
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(isPrimary ? Color.black : .white)
                .background(isPrimary ? Color.white : Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func cameraPlaceholder(text: String) -> some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .frame(height: 260)
            .overlay {
                Text(text)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding()
                    .multilineTextAlignment(.center)
            }
    }

    private func toggleSelection(for appName: String) {
        var updated = selectedApps

        if updated.contains(appName) {
            updated.remove(appName)
        } else {
            updated.insert(appName)
        }

        selectedAppsStorage = updated.sorted().joined(separator: ",")
    }
}

#Preview {
    ContentView()
}
