//
//  ContentView.swift
//  pushup
//
//  Created by Victor Deleeck on 11/04/2026.
//

import AVFoundation
import Combine
import FamilyControls
import ManagedSettings
import SwiftUI
import UIKit
import UserNotifications
import Vision

struct RepBank {
    struct Offer: Identifiable, Hashable {
        let minutes: Int
        let repCost: Int

        var id: String { "\(minutes)-\(repCost)" }
    }

    let totalReps: Int
    let spentReps: Int
    let unlockedMinutes: Int

    let offers: [Offer] = [
        Offer(minutes: 5, repCost: 2),
        Offer(minutes: 15, repCost: 5),
        Offer(minutes: 30, repCost: 10),
        Offer(minutes: 60, repCost: 20)
    ]

    var repCoins: Int {
        max(totalReps - spentReps, 0)
    }

    func canRedeem(_ offer: Offer) -> Bool {
        repCoins >= offer.repCost
    }
}

extension Date {
    var timeIntervalStorageValue: Double {
        timeIntervalSince1970
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
        #if targetEnvironment(simulator)
        accessState = .unavailable
        statusText = "Simulator does not provide live iPhone camera capture. Run this on a real device."
        #else
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
        #endif
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
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("pushupCount") private var pushupCount = 0
    @AppStorage("spentReps") private var spentReps = 0
    @AppStorage("unlockedMinutes") private var unlockedMinutes = 0
    @AppStorage("screenTimeSelectionData") private var screenTimeSelectionData = ""
    @AppStorage("unlockEndsAt") private var unlockEndsAt = 0.0

    @StateObject private var cameraModel = PushupCameraModel()
    @State private var isTrackingReps = false
    @State private var showingSpendOptions = false
    @State private var familyActivitySelection = FamilyActivitySelection()
    @State private var showingAppPicker = false
    @State private var appPickerError: String?
    @State private var hasLoadedSelection = false
    @State private var currentTime = Date()
    @State private var showingAppChangeChallenge = false
    @State private var challengeBaselineReps = 0

    private let shieldStore = ManagedSettingsStore(named: .init("pushup.shield"))
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let appChangeChallengeTarget = 5

    private var bank: RepBank {
        RepBank(
            totalReps: pushupCount,
            spentReps: spentReps,
            unlockedMinutes: unlockedMinutes
        )
    }

    private var unlockEndDate: Date? {
        unlockEndsAt > 0 ? Date(timeIntervalSince1970: unlockEndsAt) : nil
    }

    private var unlockIsActive: Bool {
        guard let unlockEndDate else { return false }
        return unlockEndDate > currentTime
    }

    private var remainingUnlockedSeconds: Int {
        guard let unlockEndDate else { return 0 }
        return max(Int(ceil(unlockEndDate.timeIntervalSince(currentTime))), 0)
    }

    private var selectedAppsCount: Int {
        familyActivitySelection.applicationTokens.count
        + familyActivitySelection.categoryTokens.count
        + familyActivitySelection.webDomainTokens.count
    }

    private var needsInitialSelection: Bool {
        hasLoadedSelection && selectedAppsCount == 0
    }

    private var challengeCompletedReps: Int {
        max(pushupCount - challengeBaselineReps, 0)
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

            if needsInitialSelection {
                onboardingView
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    balanceCard
                    cameraCard
                    selectedAppsCard
                    Spacer(minLength: 0)
                }
                .padding(20)
                .padding(.bottom, 8)
            }
        }
        .familyActivityPicker(
            headerText: "Choose apps and websites to manage",
            footerText: "These selections are used for your Screen Time setup.",
            isPresented: $showingAppPicker,
            selection: $familyActivitySelection
        )
        .overlay {
            if showingAppChangeChallenge {
                appChangeChallengeOverlay
            }
        }
        .onAppear {
            cameraModel.onRepCounted = {
                pushupCount += 1
                if showingAppChangeChallenge, challengeCompletedReps >= appChangeChallengeTarget {
                    completeAppChangeChallenge()
                }
            }
            loadSavedSelection()
            requestNotificationAuthorization()
        }
        .onDisappear {
            cameraModel.stop()
        }
        .onChange(of: familyActivitySelection) {
            guard hasLoadedSelection else { return }
            persistSelection()
            applyShields()
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                refreshUnlockState()
            }
        }
        .onReceive(timer) { _ in
            currentTime = Date()
            refreshUnlockState()
        }
    }

    private var onboardingView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(alignment: .leading, spacing: 18) {
                Text("Good choice.")
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text("You downloaded this app for a reason. Pick the apps you want to stop mindlessly opening, and the lock starts as soon as you finish choosing them.")
                    .font(.system(.title3, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))

                quickButton(title: "Select Screen Time Apps") {
                    presentInitialAppPicker()
                }

                if let appPickerError {
                    Text(appPickerError)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .padding(24)
            .background(.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )

            Spacer()
        }
        .padding(20)
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
            HStack {
                Text("Rep Bank")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))

                Spacer()

                Button(showingSpendOptions ? "Hide" : "Rot Away") {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        showingSpendOptions.toggle()
                    }
                }
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white)
                .clipShape(Capsule())
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(bank.repCoins)")
                    .font(.system(size: 54, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text("rep coins")
                    .font(.system(.title3, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }

            if unlockIsActive {
                Text("Unlocked for \(formattedUnlockTime)")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
            }

            if showingSpendOptions {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Buy minutes")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 10) {
                        ForEach(bank.offers) { offer in
                            Button {
                                redeem(offer)
                            } label: {
                                VStack(spacing: 4) {
                                    Text("\(offer.minutes)m")
                                    Text("\(offer.repCost) reps")
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                }
                                .font(.system(.body, design: .rounded))
                                .fontWeight(.bold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .foregroundStyle(bank.canRedeem(offer) ? Color.black : .white.opacity(0.45))
                                .background(bank.canRedeem(offer) ? Color.white : Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(!bank.canRedeem(offer))
                        }
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            HStack(spacing: 12) {
                statPill(title: "Reps", value: "\(pushupCount)")
                statPill(title: "Unlocked", value: "\(unlockedMinutes)m")
                statPill(title: "Spent", value: "\(spentReps)")
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
            HStack {
                Text("Rep Tracker")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                if isTrackingReps {
                    Button("Stop") {
                        isTrackingReps = false
                        cameraModel.stop()
                    }
                    .font(.system(.subheadline, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                }
            }

            if isTrackingReps {
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
                }
            } else {
                quickButton(title: "Track Reps") {
                    isTrackingReps = true
                    cameraModel.start()
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
            Button {
                handleAppsButtonTapped()
            } label: {
                HStack {
                    Text("Apps: \(selectedAppsCount)")
                        .font(.system(.headline, design: .rounded))
                        .fontWeight(.bold)
                    Spacer()
                    Image(systemName: "hourglass.circle")
                        .font(.system(size: 18, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .buttonStyle(.plain)

            if let appPickerError {
                Text(appPickerError)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appChangeChallengeOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                Text("Earn the change")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text("Do 5 pushups to change your protected apps.")
                    .font(.system(.title3, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))

                cameraSurface

                HStack {
                    Text("\(challengeCompletedReps)/\(appChangeChallengeTarget) reps")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Cancel") {
                        cancelAppChangeChallenge()
                    }
                    .font(.system(.subheadline, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                }

                ProgressView(value: Double(challengeCompletedReps), total: Double(appChangeChallengeTarget))
                    .tint(.white)

                HStack {
                    Circle()
                        .fill(cameraModel.faceDetected ? Color.green : Color.white.opacity(0.35))
                        .frame(width: 10, height: 10)
                    Text(cameraModel.statusText)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white.opacity(0.86))
                }
            }
            .padding(22)
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            )
            .padding(20)
        }
    }

    private var formattedUnlockTime: String {
        let totalSeconds = remainingUnlockedSeconds
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
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

    private func redeem(_ offer: RepBank.Offer) {
        guard bank.canRedeem(offer) else { return }
        spentReps += offer.repCost
        unlockedMinutes += offer.minutes
        let start = max(unlockEndDate ?? .now, .now)
        let endDate = start.addingTimeInterval(TimeInterval(offer.minutes * 60))
        unlockEndsAt = endDate.timeIntervalStorageValue
        scheduleUnlockNotifications(for: endDate)
        applyShields()
    }

    private func presentAppPicker() {
        Task {
            do {
                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                await MainActor.run {
                    appPickerError = nil
                    showingAppPicker = true
                }
            } catch {
                await MainActor.run {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    appPickerError = "Screen Time unavailable: \(message)"
                }
            }
        }
    }

    private func presentInitialAppPicker() {
        presentAppPicker()
    }

    private func handleAppsButtonTapped() {
        if selectedAppsCount == 0 {
            presentInitialAppPicker()
            return
        }

        beginAppChangeChallenge()
    }

    private func loadSavedSelection() {
        guard !screenTimeSelectionData.isEmpty,
              let data = Data(base64Encoded: screenTimeSelectionData),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            hasLoadedSelection = true
            applyShields()
            return
        }

        familyActivitySelection = selection
        hasLoadedSelection = true
        applyShields()
    }

    private func persistSelection() {
        guard let data = try? JSONEncoder().encode(familyActivitySelection) else { return }
        screenTimeSelectionData = data.base64EncodedString()
    }

    private func applyShields() {
        guard !unlockIsActive else {
            shieldStore.clearAllSettings()
            return
        }

        let selection = familyActivitySelection
        shieldStore.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        shieldStore.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
        shieldStore.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
        shieldStore.shield.webDomainCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
    }

    private func refreshUnlockState() {
        guard let unlockEndDate else { return }
        if unlockEndDate <= currentTime {
            unlockEndsAt = 0
            applyShields()
        }
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func scheduleUnlockNotifications(for endDate: Date) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["unlock-warning", "unlock-ended"])

        let warningInterval = endDate.timeIntervalSinceNow - 10
        if warningInterval > 0 {
            let content = UNMutableNotificationContent()
            content.title = "Time almost up"
            content.body = "Your selected apps lock again in 10 seconds."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "unlock-warning",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: warningInterval, repeats: false)
            )
            center.add(request)
        }

        let endInterval = endDate.timeIntervalSinceNow
        if endInterval > 0 {
            let content = UNMutableNotificationContent()
            content.title = "Time is up"
            content.body = "Your selected apps are locked again."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "unlock-ended",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: endInterval, repeats: false)
            )
            center.add(request)
        }
    }

    private func beginAppChangeChallenge() {
        challengeBaselineReps = pushupCount
        showingAppChangeChallenge = true
        isTrackingReps = false
        cameraModel.start()
    }

    private func cancelAppChangeChallenge() {
        showingAppChangeChallenge = false
        cameraModel.stop()
    }

    private func completeAppChangeChallenge() {
        showingAppChangeChallenge = false
        cameraModel.stop()
        presentAppPicker()
    }
}

#Preview {
    ContentView()
}
