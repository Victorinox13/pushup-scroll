//
//  ContentView.swift
//  pushup
//
//  Created by Victor Deleeck on 11/04/2026.
//

import AVFoundation
import AudioToolbox
import Combine
import CoreMotion
import DeviceActivity
import FamilyControls
import ManagedSettings
import SwiftUI
import UIKit
import UserNotifications
import Vision

struct RepBank {
    struct Offer: Identifiable, Hashable {
        let durationSeconds: Int
        let repCost: Int

        var id: String { "\(durationSeconds)-\(repCost)" }

        var label: String {
            if durationSeconds < 60 {
                return "\(durationSeconds)s"
            }
            return "\(durationSeconds / 60)m"
        }
    }

    let totalReps: Int
    let spentReps: Int
    let unlockedMinutes: Int

    let offers: [Offer] = [
            Offer(durationSeconds: 5 * 60, repCost: 2),
            Offer(durationSeconds: 15 * 60, repCost: 5),
            Offer(durationSeconds: 30 * 60, repCost: 10),
            Offer(durationSeconds: 60 * 60, repCost: 20)
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

enum OnboardingStage {
    case loading
    case appSelection
    case notificationPermission
    case cameraPermission
    case introChallenge
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

    private let smoothingFactor: CGFloat = 0.3
    private let calibrationTarget = 6
    private let lowerThreshold: CGFloat = 1.2
    private let riseThreshold: CGFloat = 1.14

    mutating func process(faceArea: CGFloat?) -> PushupDetectorUpdate {
        guard let faceArea, faceArea > 0 else {
            phase = .calibrating
            calibrationSamples = 0
            baselineArea = nil
            smoothedArea = nil
            return PushupDetectorUpdate(
                statusText: "Get in frame.",
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
                statusText: calibrationSamples >= calibrationTarget ? "Go." : "Hold still.",
                progress: 0,
                didCompleteRep: false,
                faceDetected: true
            )

        case .ready:
            guard let baselineArea else {
                phase = .calibrating
                calibrationSamples = 0
                return PushupDetectorUpdate(
                    statusText: "Resetting...",
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
                    statusText: "Up.",
                    progress: 1,
                    didCompleteRep: false,
                    faceDetected: true
                )
            }

            return PushupDetectorUpdate(
                statusText: "Down.",
                progress: progress,
                didCompleteRep: false,
                faceDetected: true
            )

        case .lowered:
            guard let baselineArea else {
                phase = .calibrating
                calibrationSamples = 0
                return PushupDetectorUpdate(
                    statusText: "Resetting...",
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
                    statusText: "Rep.",
                    progress: 0,
                    didCompleteRep: true,
                    faceDetected: true
                )
            }

            return PushupDetectorUpdate(
                statusText: "Up.",
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
    private var shouldBeRunning = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionRuntimeError),
            name: AVCaptureSession.runtimeErrorNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionInterrupted),
            name: AVCaptureSession.wasInterruptedNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionInterruptionEnded),
            name: AVCaptureSession.interruptionEndedNotification,
            object: session
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func refreshAuthorizationStatus() {
        #if targetEnvironment(simulator)
        accessState = .unavailable
        statusText = "Simulator does not provide live iPhone camera capture. Run this on a real device."
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            accessState = .granted
        case .notDetermined:
            accessState = .idle
            statusText = "Camera access is required to verify pushups."
        case .denied, .restricted:
            accessState = .denied
            statusText = "Enable camera access in Settings to track real reps."
        @unknown default:
            accessState = .failed
            statusText = "Camera authorization returned an unknown state."
        }
        #endif
    }

    func start() {
        shouldBeRunning = true
        print("[pushup] camera.start requested; sessionRunning=\(sessionRunning)")
        #if targetEnvironment(simulator)
        accessState = .unavailable
        statusText = "Simulator does not provide live iPhone camera capture. Run this on a real device."
        #else
        guard !sessionRunning else { return }

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

    func requestAccessIfNeeded(completion: ((Bool) -> Void)? = nil) {
        #if targetEnvironment(simulator)
        accessState = .unavailable
        statusText = "Simulator does not provide live iPhone camera capture. Run this on a real device."
        completion?(false)
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            accessState = .granted
            completion?(true)
        case .notDetermined:
            accessState = .requesting
            statusText = "Waiting for camera access..."
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.accessState = granted ? .granted : .denied
                    self.statusText = granted ? "Camera ready." : "Enable camera in Settings."
                    completion?(granted)
                }
            }
        case .denied, .restricted:
            accessState = .denied
            statusText = "Enable camera in Settings."
            completion?(false)
        @unknown default:
            accessState = .failed
            statusText = "Camera check failed."
            completion?(false)
        }
        #endif
    }

    func stop() {
        stop(completion: nil)
    }

    func stop(completion: (() -> Void)?) {
        shouldBeRunning = false
        print("[pushup] camera.stop requested; sessionRunning=\(sessionRunning)")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.resetTrackingState()
                self.sessionRunning = false
                print("[pushup] camera.stop completed")
                completion?()
            }
        }
    }

    private func configureAndStartIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.shouldBeRunning else { return }
            guard self.prepareSessionIfNeeded() else { return }
            guard self.shouldBeRunning else { return }

            if !self.session.isRunning {
                print("[pushup] camera.startRunning")
                self.session.startRunning()
            }

            DispatchQueue.main.async {
                guard self.shouldBeRunning else {
                    self.sessionQueue.async {
                        if self.session.isRunning {
                            self.session.stopRunning()
                        }
                    }
                    self.resetTrackingState()
                    self.sessionRunning = false
                    return
                }
                self.sessionRunning = true
                self.statusText = "Hold the top of your pushup to calibrate."
                print("[pushup] camera running")
            }
        }
    }

    private func resetTrackingState() {
        detector = PushupRepDetector()
        processedFrameCount = 0
        faceDetected = false
        repProgress = 0
        if accessState == .granted {
            statusText = "Camera ready."
        }
    }

    @objc
    private func handleSessionRuntimeError(_ notification: Notification) {
        let errorDescription = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "unknown"
        print("[pushup] camera runtime error: \(errorDescription)")
        DispatchQueue.main.async {
            self.accessState = .failed
            self.statusText = "Camera runtime error."
            self.sessionRunning = false
        }
    }

    @objc
    private func handleSessionInterrupted(_ notification: Notification) {
        print("[pushup] camera interrupted: \(String(describing: notification.userInfo))")
        DispatchQueue.main.async {
            self.statusText = "Camera interrupted."
            self.sessionRunning = false
        }
    }

    @objc
    private func handleSessionInterruptionEnded(_ notification: Notification) {
        print("[pushup] camera interruption ended")
        DispatchQueue.main.async {
            if self.shouldBeRunning {
                self.statusText = "Camera interruption ended."
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
        guard processedFrameCount.isMultiple(of: 2) else { return }

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
        if detector.phase == .ready, update.statusText == "Start." {
            update = PushupDetectorUpdate(
                statusText: "Lower down.",
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

final class FlatSurfaceMotionModel: ObservableObject {
    @Published private(set) var isMonitoring = false
    @Published private(set) var isFlat = false
    @Published private(set) var statusText = "Place your phone flat on the ground."

    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()
    private var stableSampleCount = 0

    func start() {
        guard !isMonitoring else { return }
        guard motionManager.isDeviceMotionAvailable else {
            statusText = "Motion data is unavailable on this device."
            return
        }

        print("[pushup] motion.start")
        stableSampleCount = 0
        isFlat = false
        isMonitoring = true
        statusText = "Place your phone flat on the ground."
        motionManager.deviceMotionUpdateInterval = 1.0 / 12.0
        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.statusText = "Motion check failed: \(error.localizedDescription)"
                    self.isMonitoring = false
                }
                return
            }
            guard let motion else { return }

            let gravity = motion.gravity
            let isScreenUpFlat = abs(gravity.x) < 0.16 && abs(gravity.y) < 0.16 && gravity.z < -0.94

            if isScreenUpFlat {
                stableSampleCount += 1
            } else {
                stableSampleCount = 0
            }

            let stableEnough = stableSampleCount >= 4
            DispatchQueue.main.async {
                self.isFlat = stableEnough
                self.statusText = stableEnough
                    ? "Phone locked flat. Tracker armed."
                    : "Lay the phone flat with the screen facing up."
            }
        }
    }

    func stop() {
        guard isMonitoring else { return }
        print("[pushup] motion.stop")
        motionManager.stopDeviceMotionUpdates()
        stableSampleCount = 0
        isMonitoring = false
        isFlat = false
        statusText = "Place your phone flat on the ground."
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
    @AppStorage("hasCompletedInitialSetup") private var hasCompletedInitialSetup = false
    @AppStorage("hasShownMainMenuAdGate") private var hasShownMainMenuAdGate = false
    @AppStorage("hasAcknowledgedNotificationPrompt") private var hasAcknowledgedNotificationPrompt = false
    @AppStorage("hasAcknowledgedCameraPrompt") private var hasAcknowledgedCameraPrompt = false
    @AppStorage("trackerLightAssistEnabled") private var trackerLightAssistEnabled = false

    @StateObject private var bannerLoadState = BannerLoadState.shared
    @StateObject private var cameraModel = PushupCameraModel()
    @StateObject private var flatSurfaceModel = FlatSurfaceMotionModel()
    @StateObject private var rewardedAdManager = RewardedAdManager()
    @State private var pendingUnlockOffer: RepBank.Offer?
    @State private var isTrackingReps = false
    @State private var showingSpendOptions = false
    @State private var showingActiveUnlockWarning = false
    @State private var showingRewardBreakPrompt = false
    @State private var showingRotAwayPrompt = false
    @State private var showingMainMenuAdGate = false
    @State private var familyActivitySelection = FamilyActivitySelection()
    @State private var showingAppPicker = false
    @State private var appPickerError: String?
    @State private var hasLoadedSelection = false
    @State private var currentTime = Date()
    @State private var showingAppChangeChallenge = false
    @State private var challengeBaselineReps = 0
    @State private var showingLaunchScreen = true
    @State private var onboardingBaselineReps = 0
    @State private var hasPreparedOnboardingChallenge = false
    @State private var showingPermissionStatusSheet = false
    @State private var showingAppEditIntro = false
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var screenTimeAuthorizationStatus: AuthorizationStatus = .notDetermined
    @State private var isRequestingNotificationPermission = false
    @State private var isRequestingScreenTimePermission = false
    @State private var isOpeningRepTracker = false
    @State private var showingMindfulPause = false
    @State private var mindfulPauseSecondsRemaining = 15
    @State private var mindfulPauseQuoteIndex = 0
    @State private var mindfulPauseSession = 0
    @State private var previousScreenBrightness: CGFloat?
    @State private var loadingPushupDown = false

    private let shieldStore = ManagedSettingsStore(named: .init("pushup.shield"))
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let appChangeChallengeTarget = 5
    private let introChallengeTarget = 5
    private let privacyPolicyURL = URL(string: "https://privacypolicyurl.com/pushtounrot/privacy-policy.html")
    private let sharedDefaultsSuiteName = "group.deleeck.pushtounrot.shared"
    private let sharedSelectionKey = "screenTimeSelectionData"
    private let sharedUnlockEndsAtKey = "unlockEndsAt"
    private let unlockMonitorName = DeviceActivityName("deleeck.pushtounrot.unlock-monitor")

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

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: sharedDefaultsSuiteName)
    }

    private var onboardingStage: OnboardingStage? {
        if showingLaunchScreen || !hasLoadedSelection {
            return .loading
        }

        guard !hasCompletedInitialSetup else { return nil }

        if selectedAppsCount == 0 {
            return .appSelection
        }

        if !hasAcknowledgedNotificationPrompt,
           notificationAuthorizationStatus == .notDetermined {
            return .notificationPermission
        }

        if hasAcknowledgedCameraPrompt && !cameraPermissionGranted {
            return nil
        }

        switch cameraModel.accessState {
        case .granted:
            return .introChallenge
        case .idle, .requesting:
            return .cameraPermission
        case .denied, .unavailable, .failed:
            return nil
        }
    }

    private var challengeCompletedReps: Int {
        max(pushupCount - challengeBaselineReps, 0)
    }

    private var onboardingCompletedReps: Int {
        max(pushupCount - onboardingBaselineReps, 0)
    }

    var body: some View {
        ZStack {
            themeBackground

            if let onboardingStage {
                onboardingView(for: onboardingStage)
            } else if showingMainMenuAdGate {
                mainMenuLoadingView
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        balanceCard
                        cameraCard
                        selectedAppsCard
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .padding(.bottom, 84)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if onboardingStage == nil {
                persistentBannerBar
            }
        }
        .sheet(isPresented: $showingAppPicker, onDismiss: {
            print("[pushup] app picker dismissed")
            refreshPermissionStatuses()
        }) {
            appPickerSheet
        }
        .sheet(isPresented: $showingPermissionStatusSheet) {
            permissionStatusSheet
        }
        .overlay {
            if showingAppChangeChallenge {
                appChangeChallengeOverlay
            } else if showingAppEditIntro {
                appEditIntroOverlay
            } else if showingMindfulPause {
                mindfulPauseOverlay
            } else if showingSpendOptions {
                spendOptionsOverlay
            } else if isTrackingReps {
                repTrackerOverlay
            }
        }
        .onAppear {
            print("[pushup] content view appeared")
            cameraModel.onRepCounted = {
                pushupCount += 1
                playRepCompletionFeedback()
                print("[pushup] rep counted; total=\(pushupCount)")
                if !hasCompletedInitialSetup,
                   onboardingCompletedReps >= introChallengeTarget {
                    completeInitialSetup()
                }
                if showingAppChangeChallenge, challengeCompletedReps >= appChangeChallengeTarget {
                    completeAppChangeChallenge()
                }
            }
            rewardedAdManager.preload(adUnitID: rewardedAdUnitID)
            startInitialLoad()
        }
        .onDisappear {
            print("[pushup] content view disappeared")
            restoreScreenBrightnessIfNeeded()
            cameraModel.stop()
            flatSurfaceModel.stop()
        }
        .onChange(of: familyActivitySelection) {
            guard hasLoadedSelection else { return }
            print("[pushup] family activity selection changed; apps=\(familyActivitySelection.applicationTokens.count) categories=\(familyActivitySelection.categoryTokens.count) domains=\(familyActivitySelection.webDomainTokens.count)")
            persistSelection()
            applyShields()
            if unlockIsActive, let unlockEndDate {
                scheduleUnlockMonitor(for: unlockEndDate)
            }
            if !hasCompletedInitialSetup, selectedAppsCount > 0 {
                cameraModel.refreshAuthorizationStatus()
            }
        }
        .onChange(of: showingSpendOptions) {
            if showingSpendOptions {
                rewardedAdManager.preload(adUnitID: rewardedAdUnitID)
            }
        }
        .onChange(of: hasCompletedInitialSetup) {
            if hasCompletedInitialSetup && !hasShownMainMenuAdGate {
                beginMainMenuAdGate()
            }
        }
        .onChange(of: bannerLoadState.isLoaded) {
            if showingMainMenuAdGate && bannerLoadState.isLoaded {
                finishMainMenuAdGate()
            }
        }
        .onChange(of: showingAppPicker) {
            print("[pushup] showingAppPicker -> \(showingAppPicker)")
        }
        .onChange(of: cameraModel.sessionRunning) {
            if cameraModel.sessionRunning {
                isOpeningRepTracker = false
            }
        }
        .onChange(of: cameraModel.accessState) {
            if cameraModel.accessState == .failed || cameraModel.accessState == .denied || cameraModel.accessState == .unavailable {
                isOpeningRepTracker = false
            }
        }
        .onChange(of: flatSurfaceModel.isFlat) {
            if flatSurfaceModel.isFlat {
                if isTrackingReps, !cameraModel.sessionRunning, cameraModel.accessState != .requesting {
                    cameraModel.start()
                }
                if showingAppChangeChallenge, !cameraModel.sessionRunning, cameraModel.accessState != .requesting {
                    cameraModel.start()
                }
            } else if isTrackingReps || showingAppChangeChallenge {
                cameraModel.stop()
            }
        }
        .onChange(of: trackerLightAssistEnabled) {
            updateTrackerLightAssist()
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                print("[pushup] scene became active")
                refreshUnlockState()
                refreshPermissionStatuses()
                updateTrackerLightAssist()
            }
        }
        .onReceive(timer) { _ in
            currentTime = Date()
            refreshUnlockState()
        }
        .alert("Healthy break", isPresented: $showingRewardBreakPrompt) {
            Button("Not now", role: .cancel) {}
            Button("Watch ad (instant) to scroll") {
                watchRewardedBreak()
            }
            Button("Wait 15s") {
                startMindfulPause()
            }
        } message: {
            Text("A short ad can interrupt the urge to keep scrolling. Finish it and then choose how to spend your rep coins.")
        }
        .alert("Pause first", isPresented: $showingRotAwayPrompt) {
            Button("Cancel", role: .cancel) {}
            Button("Watch ad (instant)") {
                watchRewardedBreak()
            }
            Button("Wait 15s") {
                startMindfulPause()
            }
        } message: {
            Text("Before you rot away, take a short pause. Watch an ad to scroll, or cancel and stay locked in.")
        }
        .alert("Keep RepCoin Open", isPresented: $showingActiveUnlockWarning) {
            Button("Cancel", role: .cancel) {
                pendingUnlockOffer = nil
            }
            Button("Start Timer") {
                confirmPendingUnlock()
            }
        } message: {
            Text("While your timer is active, do not swipe RepCoin away in the app switcher. iPhone may stop automatic relocking if the app is force-quit.")
        }
    }

    @ViewBuilder
    private func onboardingView(for stage: OnboardingStage) -> some View {
        switch stage {
        case .loading:
            loadingView
        case .appSelection:
            initialAppSelectionView
        case .notificationPermission:
            notificationPermissionView
        case .cameraPermission:
            cameraPermissionView
        case .introChallenge:
            introChallengeView
        }
    }

    private var loadingView: some View {
        VStack {
            Spacer()

            loadingPushupAnimation
                .frame(maxWidth: .infinity)
            .onAppear {
                guard !loadingPushupDown else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    loadingPushupDown = true
                }
            }

            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private var mainMenuLoadingView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(alignment: .leading, spacing: 20) {
                startupCardTitle("Loading Home", size: 38)

                Text("Setting up your main menu and loading the first banner.")
                    .font(.system(.title3, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)

                HStack(spacing: 12) {
                    ProgressView()
                        .tint(AppTheme.accent)
                    Text("Almost there...")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .liquidGlassPanel(cornerRadius: 30, tint: AppTheme.panelTint)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(20)
    }

    private var loadingPushupAnimation: some View {
        ZStack {
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 34, height: 34)
                    .shadow(color: Color.white.opacity(0.25), radius: 8)
                    .offset(y: loadingPushupDown ? 34 : -16)

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.accentBright)
                    .frame(width: 120, height: 18)
                    .rotationEffect(.degrees(loadingPushupDown ? 10 : -12), anchor: .leading)
                    .offset(y: loadingPushupDown ? 10 : -4)
                    .shadow(color: AppTheme.accentBright.opacity(0.28), radius: 10)

                HStack(spacing: 18) {
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 18, height: 92)
                        .rotationEffect(.degrees(loadingPushupDown ? 28 : 8), anchor: .top)
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 18, height: 92)
                        .rotationEffect(.degrees(loadingPushupDown ? -6 : -24), anchor: .top)
                }
                .offset(y: loadingPushupDown ? -2 : -18)
            }
            .shadow(color: Color.black.opacity(0.18), radius: 20, y: 10)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.18))
                .frame(height: 12)
                .frame(maxWidth: 220)
                .offset(y: 74)
        }
        .frame(height: 220)
    }

    private var initialAppSelectionView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(alignment: .leading, spacing: 14) {
                startupCardTitle("Lock in your blockers", size: 36)

                Text("Choose the apps or websites you want protected. Once they are set, you will allow camera access and finish 5 real pushups to enter the app.")
                    .font(.system(.title3, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)

                quickButton(title: "Choose Protected Apps") {
                    presentInitialAppPicker()
                }
                .disabled(isRequestingScreenTimePermission)

                if let appPickerError {
                    Text(appPickerError)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .liquidGlassPanel(cornerRadius: 30, tint: AppTheme.panelTint)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(20)
    }

    private var cameraPermissionView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(alignment: .leading, spacing: 18) {
                startupCardTitle("Allow the camera", size: 36)

                Text(cameraPermissionDescription)
                    .font(.system(.title3, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)

                cameraPlaceholder(text: cameraPermissionStatusText)

                quickButton(title: cameraPermissionActionTitle) {
                    handleCameraPermissionAction()
                }
            }
            .liquidGlassPanel(cornerRadius: 30, tint: AppTheme.panelTint)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(20)
    }

    private var notificationPermissionView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(alignment: .leading, spacing: 18) {
                startupCardTitle("Allow notifications", size: 36)

                Text(notificationPermissionDescription)
                    .font(.system(.title3, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)

                cameraPlaceholder(text: notificationPermissionStatusText)

                quickButton(title: notificationPermissionActionTitle) {
                    handleNotificationPermissionAction()
                }
                .disabled(isRequestingNotificationPermission)
            }
            .liquidGlassPanel(cornerRadius: 30, tint: AppTheme.panelTint)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(20)
    }

    private var introChallengeView: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 18) {
                startupCardTitle("Earn your start", size: 36)

                Text("Do 5 full pushups to finish setup. The camera counts a rep only after a full down-and-up motion.")
                    .font(.system(.title3, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)

                cameraSurface

                HStack {
                    Text("\(onboardingCompletedReps)/\(introChallengeTarget) reps")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(cameraModel.faceDetected ? "Face locked" : "Find your frame")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                ProgressView(value: Double(onboardingCompletedReps), total: Double(introChallengeTarget))
                    .tint(AppTheme.accent)

                HStack {
                    Circle()
                        .fill(cameraModel.faceDetected ? AppTheme.accentBright : Color.white.opacity(0.28))
                        .frame(width: 10, height: 10)
                    Text(cameraModel.statusText)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .liquidGlassPanel(cornerRadius: 30, tint: AppTheme.panelTint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .onAppear {
                startInitialPushupChallengeIfNeeded()
            }

            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text("Earn your scroll")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    showingPermissionStatusSheet = true
                } label: {
                    Image(systemName: "checklist")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .liquidGlassButtonBackground(cornerRadius: 16, tint: AppTheme.softTint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Permission status")
            }

            Text("Earn time with reps.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(AppTheme.secondaryText)
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
                    showingRotAwayPrompt = true
                }
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .liquidGlassCapsuleButton(tint: AppTheme.softTint)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(bank.repCoins)")
                    .font(.system(size: 54, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text("rep coins")
                    .font(.system(.title3, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            if unlockIsActive {
                HStack(spacing: 8) {
                    Text("Time Left")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryText)
                        .textCase(.uppercase)

                    Text(formattedUnlockTime)
                        .font(.system(.headline, design: .rounded))
                        .fontWeight(.heavy)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .liquidGlassPanel(cornerRadius: 16, tint: AppTheme.softTint, padding: 0)
            }

            HStack(spacing: 12) {
                statPill(title: "Reps", value: "\(pushupCount)")
                statPill(title: "Rotted", value: "\(unlockedMinutes)m")
            }
        }
        .liquidGlassPanel(cornerRadius: 28, tint: AppTheme.panelTint)
    }

    private var spendOptionsOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        showingSpendOptions = false
                    }
                }

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Rot Away")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Hide") {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            showingSpendOptions = false
                        }
                    }
                    .font(.system(.subheadline, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .liquidGlassCapsuleButton(tint: .white.opacity(0.18))
                }

                Text("Spend rep coins to buy scroll time.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 10)], spacing: 10) {
                    ForEach(bank.offers) { offer in
                        Button {
                            pendingUnlockOffer = offer
                            showingActiveUnlockWarning = true
                        } label: {
                            VStack(spacing: 4) {
                                Text(offer.label)
                                Text("\(offer.repCost) reps")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                            }
                            .font(.system(.body, design: .rounded))
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(bank.canRedeem(offer) ? Color.white : .white.opacity(0.45))
                            .liquidGlassButtonBackground(
                                cornerRadius: 18,
                                tint: bank.canRedeem(offer) ? AppTheme.accent.opacity(0.32) : AppTheme.softTint,
                                interactive: bank.canRedeem(offer)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!bank.canRedeem(offer))
                    }
                }

            }
            .liquidGlassPanel(cornerRadius: 28, tint: AppTheme.panelTint)
            .padding(20)
        }
    }

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Rep Arena")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()
            }

            Text(isTrackingReps ? "Live tracker open." : "Open the live counter.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(AppTheme.secondaryText)

                quickButton(title: repTrackerButtonTitle) {
                    openRepTracker()
                }
                .disabled(isTrackingReps || isOpeningRepTracker)

            if isOpeningRepTracker {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(AppTheme.accent)
                    Text(flatSurfaceModel.isFlat ? "Opening..." : "Set phone flat...")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
        }
        .liquidGlassPanel(cornerRadius: 28, tint: AppTheme.panelTint)
    }

    @ViewBuilder
    private var cameraSurface: some View {
        switch cameraModel.accessState {
        case .granted, .idle:
            CameraPreviewView(session: cameraModel.session)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    if trackerLightAssistEnabled {
                        cameraFrameOutline(cornerRadius: 24)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    Text(cameraModel.sessionRunning ? "LIVE" : "STARTING")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .liquidGlassButtonBackground(cornerRadius: 999, tint: AppTheme.softTint)
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
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rotting Apps")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.white)

                    Text("\(selectedAppsCount) protected")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Spacer()

                Button(isRequestingScreenTimePermission ? "Loading..." : "Edit") {
                    handleAppsButtonTapped()
                }
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .liquidGlassCapsuleButton(tint: AppTheme.softTint)
                .disabled(isRequestingScreenTimePermission)
            }

            rottingAppsPreview

            if let appPickerError {
                Text(appPickerError)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .liquidGlassPanel(cornerRadius: 28, tint: AppTheme.panelTint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var persistentBannerBar: some View {
        VStack(spacing: 0) {
            AdMobBannerContainer(adUnitID: bannerAdUnitID)
                .frame(maxWidth: .infinity)
                .frame(height: 72)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                )
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 10)
        }
        .background(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.04),
                    Color.black.opacity(0.28)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .background(.ultraThinMaterial)
        )
    }

    private var mindfulPauseOverlay: some View {
        ZStack {
            Color.black.opacity(0.78)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 20) {
                    Text("Take 15 Seconds")
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)

                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.10), lineWidth: 16)
                            .frame(width: 200, height: 200)

                        Circle()
                            .trim(from: 0, to: mindfulPauseProgress)
                            .stroke(
                                LinearGradient(
                                    colors: [AppTheme.accentBright, AppTheme.accent],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                style: StrokeStyle(lineWidth: 16, lineCap: .round)
                            )
                            .frame(width: 200, height: 200)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.8), value: mindfulPauseProgress)

                        VStack(spacing: 6) {
                            Text("\(mindfulPauseSecondsRemaining)")
                                .font(.system(size: 60, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                                .contentTransition(.numericText())

                            Text("seconds")
                                .font(.system(.headline, design: .rounded))
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }

                    Text(mindfulPauseQuotes[mindfulPauseQuoteIndex])
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 76, alignment: .center)
                        .padding(.horizontal, 12)
                        .id(mindfulPauseQuoteIndex)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        .animation(.spring(response: 0.7, dampingFraction: 0.82), value: mindfulPauseQuoteIndex)
                }
                .frame(maxWidth: 360)
                .liquidGlassPanel(cornerRadius: 32, tint: AppTheme.panelTint, padding: 24)
                .padding(.horizontal, 20)

                Spacer()
            }
        }
    }

    private var bannerAdUnitID: String {
        #if DEBUG
        return "ca-app-pub-3940256099942544/2435281174"
        #else
        return "ca-app-pub-9559509402865286/5722560573"
        #endif
    }

    private var rewardedAdUnitID: String {
        #if DEBUG
        return "ca-app-pub-3940256099942544/1712485313"
        #else
        return "ca-app-pub-9559509402865286/2813326208"
        #endif
    }

    @ViewBuilder
    private var rottingAppsPreview: some View {
        if selectedAppsCount == 0 {
            Text("No rotting apps picked yet.")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(AppTheme.secondaryText)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(familyActivitySelection.applicationTokens.prefix(4)), id: \.self) { token in
                    Label(token)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white)
                        .labelStyle(.titleAndIcon)
                }

                ForEach(Array(familyActivitySelection.categoryTokens.prefix(2)), id: \.self) { token in
                    Label(token)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white)
                        .labelStyle(.titleAndIcon)
                }

                ForEach(Array(familyActivitySelection.webDomainTokens.prefix(2)), id: \.self) { token in
                    Label(token)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white)
                        .labelStyle(.titleAndIcon)
                }

                if selectedAppsCount > 8 {
                    Text("+ \(selectedAppsCount - 8) more")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .padding(14)
            .liquidGlassButtonBackground(cornerRadius: 18, tint: AppTheme.softTint, interactive: false)
        }
    }

    private var repTrackerOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture {
                    closeRepTracker()
                }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Rep Arena")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Close") {
                        closeRepTracker()
                    }
                    .font(.system(.subheadline, design: .rounded))
                    .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .liquidGlassCapsuleButton(tint: .white.opacity(0.18))
                }

                HStack(spacing: 10) {
                    Image(systemName: flatSurfaceModel.isFlat ? "checkmark.circle.fill" : "iphone.gen3.radiowaves.left.and.right")
                        .foregroundStyle(flatSurfaceModel.isFlat ? AppTheme.accentBright : AppTheme.gold)
                    Text(flatSurfaceModel.isFlat ? "Phone flat." : "Set phone flat.")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlassButtonBackground(cornerRadius: 18, tint: AppTheme.softTint, interactive: false)

                Toggle(isOn: $trackerLightAssistEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Light Assist")
                            .font(.system(.subheadline, design: .rounded))
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                        Text("Bright frame + max screen glow")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .tint(AppTheme.accentBright)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlassButtonBackground(cornerRadius: 18, tint: AppTheme.softTint, interactive: false)

                trackerCameraSurface

                HStack(spacing: 10) {
                    Circle()
                        .fill(cameraModel.faceDetected ? AppTheme.accentBright : Color.white.opacity(0.35))
                        .frame(width: 10, height: 10)
                    Text(cameraModel.statusText)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                HStack(spacing: 10) {
                    trackerStatBadge(title: "Total", value: "\(pushupCount)")
                    trackerStatBadge(title: "Coins", value: "\(bank.repCoins)")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .liquidGlassPanel(cornerRadius: 28, tint: AppTheme.panelTint, padding: 16)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    private var appPickerSheet: some View {
        NavigationStack {
            FamilyActivityPicker(selection: $familyActivitySelection)
                .navigationTitle("Choose Apps")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            print("[pushup] app picker done tapped")
                            showingAppPicker = false
                        }
                    }
                }
                .onAppear {
                    print("[pushup] app picker sheet appeared")
                }
        }
    }

    private var repTrackerButtonTitle: String {
        if isTrackingReps {
            return "Tracker Open"
        }
        if isOpeningRepTracker {
            return "Opening..."
        }
        return "Track Reps"
    }

    private var appChangeChallengeOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("5 Pushups")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Cancel") {
                        cancelAppChangeChallenge()
                    }
                    .font(.system(.subheadline, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .liquidGlassCapsuleButton(tint: .white.opacity(0.18))
                }

                motionStatusBanner

                trackerCameraSurface

                Text("\(challengeCompletedReps)/\(appChangeChallengeTarget) reps")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)

                ProgressView(value: Double(challengeCompletedReps), total: Double(appChangeChallengeTarget))
                    .tint(AppTheme.accent)
            }
            .fixedSize(horizontal: false, vertical: true)
            .liquidGlassPanel(cornerRadius: 28, tint: AppTheme.panelTint, padding: 16)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    private var appEditIntroOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                Text("Change Your Rotting Apps")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text("You need 5 pushups before you can change this list.")
                    .font(.system(.title3, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))

                HStack(spacing: 12) {
                    Button("Cancel") {
                        showingAppEditIntro = false
                    }
                    .font(.system(.subheadline, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .liquidGlassCapsuleButton(tint: .white.opacity(0.18))

                    quickButton(title: "Continue") {
                        showingAppEditIntro = false
                        beginAppChangeChallenge()
                    }
                }
            }
            .liquidGlassPanel(cornerRadius: 28, tint: AppTheme.panelTint)
            .padding(20)
        }
    }

    private var permissionStatusSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                permissionRow(
                    title: "Screen Time",
                    status: screenTimePermissionLabel,
                    isEnabled: screenTimePermissionGranted,
                    detail: "Required to choose and shield apps."
                )
                permissionRow(
                    title: "Notifications",
                    status: notificationPermissionLabel,
                    isEnabled: notificationsAreEnabled,
                    detail: "Optional unlock ending reminders."
                )
                permissionRow(
                    title: "Camera",
                    status: cameraPermissionLabel,
                    isEnabled: cameraPermissionGranted,
                    detail: "Used to count real pushup reps."
                )

                Spacer(minLength: 0)

                quickButton(title: "Refresh", isPrimary: false) {
                    refreshPermissionStatuses()
                }

                quickButton(title: "Privacy Policy", isPrimary: false) {
                    openPrivacyPolicy()
                }

                if !notificationsAreEnabled || !cameraPermissionGranted {
                    quickButton(title: "Open Settings") {
                        openAppSettings()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(themeBackground)
            .navigationTitle("Permissions")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
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
                .foregroundStyle(AppTheme.secondaryText)
            Text(value)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.heavy)
                .foregroundStyle(.white)
        }
        .liquidGlassPanel(cornerRadius: 18, tint: AppTheme.softTint, padding: 14)
    }

    private func quickButton(title: String, isPrimary: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.body, design: .rounded))
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(.white)
                .liquidGlassButtonBackground(
                    cornerRadius: 20,
                    tint: isPrimary ? AppTheme.accent.opacity(0.32) : AppTheme.softTint
                )
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func startupCardTitle(_ title: String, size: CGFloat) -> some View {
        Text(title)
            .font(.system(size: size, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.65)
            .allowsTightening(true)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trackerStatBadge(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.secondaryText)
            Text(value)
                .font(.system(.headline, design: .rounded))
                .fontWeight(.heavy)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlassButtonBackground(cornerRadius: 16, tint: AppTheme.softTint, interactive: false)
    }

    private var motionStatusBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: flatSurfaceModel.isFlat ? "checkmark.circle.fill" : "iphone.gen3.radiowaves.left.and.right")
                .foregroundStyle(flatSurfaceModel.isFlat ? AppTheme.accentBright : AppTheme.gold)
            Text(flatSurfaceModel.statusText)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassButtonBackground(cornerRadius: 18, tint: AppTheme.softTint, interactive: false)
    }

    private func permissionRow(title: String, status: String, isEnabled: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: isEnabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isEnabled ? AppTheme.accentBright : Color.red.opacity(0.88))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(status)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Text(detail)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .liquidGlassPanel(cornerRadius: 24, tint: AppTheme.panelTint, padding: 16)
    }

    private func cameraPlaceholder(text: String) -> some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(AppTheme.softTint)
            .frame(height: 260)
            .overlay {
                Text(text)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding()
                    .multilineTextAlignment(.center)
            }
    }

    private var trackerCameraSurface: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                switch cameraModel.accessState {
                case .granted, .idle:
                    if flatSurfaceModel.isFlat {
                        CameraPreviewView(session: cameraModel.session)
                    } else {
                        cameraSquarePlaceholder(text: "Phone not flat yet.")
                    }
                case .requesting:
                    cameraSquarePlaceholder(text: "Requesting camera access...")
                case .denied:
                    cameraSquarePlaceholder(text: "Camera access is off. Enable it in Settings.")
                case .unavailable:
                    cameraSquarePlaceholder(text: "This device does not have a usable front camera.")
                case .failed:
                    cameraSquarePlaceholder(text: "The camera session could not be started.")
                }
            }
            .frame(width: 270, height: 270)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                if trackerLightAssistEnabled {
                    cameraFrameOutline(cornerRadius: 28)
                }
            }
            Text(cameraModel.sessionRunning ? "LIVE" : "STARTING")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .liquidGlassButtonBackground(cornerRadius: 999, tint: AppTheme.softTint, interactive: false)
                .padding(14)
        }
        .frame(maxWidth: .infinity)
    }

    private func cameraSquarePlaceholder(text: String) -> some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(AppTheme.softTint)
            .overlay {
                Text(text)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding()
                    .multilineTextAlignment(.center)
            }
    }

    private func cameraFrameOutline(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.95),
                        AppTheme.accentBright.opacity(0.95),
                        Color.white.opacity(0.9)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 4
            )
            .shadow(color: Color.white.opacity(0.35), radius: 12)
            .shadow(color: AppTheme.accentBright.opacity(0.32), radius: 22)
    }

    private func updateTrackerLightAssist() {
        guard isTrackingReps else {
            restoreScreenBrightnessIfNeeded()
            return
        }

        guard trackerLightAssistEnabled else {
            restoreScreenBrightnessIfNeeded()
            return
        }

        if previousScreenBrightness == nil {
            previousScreenBrightness = UIScreen.main.brightness
        }
        UIScreen.main.brightness = 1
    }

    private func playRepCompletionFeedback() {
        let haptic = UINotificationFeedbackGenerator()
        haptic.prepare()
        haptic.notificationOccurred(.success)
        AudioServicesPlaySystemSound(1057)
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }

    private func restoreScreenBrightnessIfNeeded() {
        guard let previousScreenBrightness else { return }
        UIScreen.main.brightness = previousScreenBrightness
        self.previousScreenBrightness = nil
    }

    private var mindfulPauseProgress: CGFloat {
        let totalSeconds: CGFloat = 15
        let completedSeconds = totalSeconds - CGFloat(mindfulPauseSecondsRemaining)
        return min(max(completedSeconds / totalSeconds, 0), 1)
    }

    private var mindfulPauseQuotes: [String] {
        [
            "Scrolling is easy. Recovery is earned.",
            "Your attention is worth more than one more swipe.",
            "Pause long enough to choose on purpose.",
            "A short reset beats a long spiral.",
            "Protect your focus before the feed takes it."
        ]
    }

    private func redeem(_ offer: RepBank.Offer) {
        guard bank.canRedeem(offer) else { return }
        spentReps += offer.repCost
        if offer.durationSeconds >= 60 {
            unlockedMinutes += offer.durationSeconds / 60
        }
        let start = max(unlockEndDate ?? .now, .now)
        let endDate = start.addingTimeInterval(TimeInterval(offer.durationSeconds))
        unlockEndsAt = endDate.timeIntervalStorageValue
        syncSharedUnlockState(endDate.timeIntervalStorageValue)
        scheduleUnlockNotifications(for: endDate)
        scheduleUnlockMonitor(for: endDate)
        applyShields()
        pendingUnlockOffer = nil
    }

    private func confirmPendingUnlock() {
        guard let pendingUnlockOffer else { return }
        redeem(pendingUnlockOffer)
    }

    private func watchRewardedBreak() {
        rewardedAdManager.showAd(adUnitID: rewardedAdUnitID) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                showingSpendOptions = true
            }
        }
    }

    private func startMindfulPause() {
        mindfulPauseSession += 1
        let session = mindfulPauseSession

        mindfulPauseSecondsRemaining = 15
        mindfulPauseQuoteIndex = 0
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            showingMindfulPause = true
        }

        Task { @MainActor in
            for elapsedSecond in 1...15 {
                try? await Task.sleep(for: .seconds(1))
                guard session == mindfulPauseSession, showingMindfulPause else { return }

                mindfulPauseSecondsRemaining = max(15 - elapsedSecond, 0)

                let nextQuoteIndex = min(elapsedSecond / 3, mindfulPauseQuotes.count - 1)
                if nextQuoteIndex != mindfulPauseQuoteIndex {
                    withAnimation(.spring(response: 0.7, dampingFraction: 0.82)) {
                        mindfulPauseQuoteIndex = nextQuoteIndex
                    }
                }
            }

            guard session == mindfulPauseSession else { return }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                showingMindfulPause = false
                showingSpendOptions = true
            }
        }
    }

    private func presentAppPicker() {
        print("[pushup] presentAppPicker called; selectedAppsCount=\(selectedAppsCount)")
        isTrackingReps = false
        showingAppChangeChallenge = false
        cameraModel.stop {
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                await MainActor.run {
                    isRequestingScreenTimePermission = true
                    print("[pushup] requesting Screen Time authorization")
                }
                do {
                    try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                    await MainActor.run {
                        screenTimeAuthorizationStatus = AuthorizationCenter.shared.authorizationStatus
                        appPickerError = nil
                        isRequestingScreenTimePermission = false
                        print("[pushup] Screen Time authorization success; status=\(String(describing: screenTimeAuthorizationStatus))")
                        showingAppPicker = true
                    }
                } catch {
                    await MainActor.run {
                        screenTimeAuthorizationStatus = AuthorizationCenter.shared.authorizationStatus
                        isRequestingScreenTimePermission = false
                        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        appPickerError = "Screen Time unavailable: \(message)"
                        print("[pushup] Screen Time authorization failed: \(message)")
                    }
                }
            }
        }
    }

    private func presentInitialAppPicker() {
        presentAppPicker()
    }

    private func handleAppsButtonTapped() {
        print("[pushup] selected apps button tapped")
        appPickerError = nil
        if selectedAppsCount == 0 {
            presentAppPicker()
            return
        }
        showingAppEditIntro = true
    }

    private func openRepTracker() {
        guard !isTrackingReps, !isOpeningRepTracker else { return }
        print("[pushup] opening rep tracker")
        isOpeningRepTracker = true
        isTrackingReps = true
        updateTrackerLightAssist()
        flatSurfaceModel.start()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if flatSurfaceModel.isFlat {
                isOpeningRepTracker = false
            }
        }
    }

    private func closeRepTracker() {
        print("[pushup] closing rep tracker")
        isOpeningRepTracker = false
        isTrackingReps = false
        restoreScreenBrightnessIfNeeded()
        cameraModel.stop()
        flatSurfaceModel.stop()
    }

    private func loadSavedSelection() {
        if screenTimeSelectionData.isEmpty,
           let sharedSelectionData = sharedDefaults?.string(forKey: sharedSelectionKey),
           !sharedSelectionData.isEmpty {
            screenTimeSelectionData = sharedSelectionData
        }

        syncUnlockStateFromSharedDefaults()

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

    private func startInitialLoad() {
        print("[pushup] initial load started")
        loadSavedSelection()
        refreshPermissionStatuses()

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.1))
            showingLaunchScreen = false
        }
    }

    private func persistSelection() {
        guard let data = try? JSONEncoder().encode(familyActivitySelection) else { return }
        let encodedSelection = data.base64EncodedString()
        screenTimeSelectionData = encodedSelection
        sharedDefaults?.set(encodedSelection, forKey: sharedSelectionKey)
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
        syncUnlockStateFromSharedDefaults()
        guard let unlockEndDate else { return }
        if unlockEndDate <= currentTime {
            clearActiveUnlock()
            applyShields()
        }
    }

    private func clearActiveUnlock() {
        unlockEndsAt = 0
        syncSharedUnlockState(0)
        stopUnlockMonitor()
    }

    private func syncSharedUnlockState(_ value: Double) {
        sharedDefaults?.set(value, forKey: sharedUnlockEndsAtKey)
    }

    private func syncUnlockStateFromSharedDefaults() {
        guard let sharedDefaults else { return }
        let sharedUnlockEndsAt = sharedDefaults.double(forKey: sharedUnlockEndsAtKey)
        if sharedUnlockEndsAt > 0 {
            let localUnlockEndsAt = unlockEndsAt
            if sharedUnlockEndsAt > localUnlockEndsAt {
                unlockEndsAt = sharedUnlockEndsAt
            }
        } else if unlockEndsAt <= currentTime.timeIntervalSince1970 {
            unlockEndsAt = sharedUnlockEndsAt
        }
    }

    private func scheduleUnlockMonitor(for endDate: Date) {
        guard selectedAppsCount > 0 else {
            stopUnlockMonitor()
            return
        }

        let now = Date()
        guard endDate > now else {
            clearActiveUnlock()
            applyShields()
            return
        }

        let scheduleStartDate = endDate
        let scheduleEndDate = endDate.addingTimeInterval(120)

        let schedule = DeviceActivitySchedule(
            intervalStart: monitorDateComponents(for: scheduleStartDate),
            intervalEnd: monitorDateComponents(for: scheduleEndDate),
            repeats: false
        )

        let center = DeviceActivityCenter()
        center.stopMonitoring([unlockMonitorName])

        do {
            try center.startMonitoring(unlockMonitorName, during: schedule)
            print("[pushup] unlock monitor scheduled; startsAt=\(scheduleStartDate) endsAt=\(scheduleEndDate)")
        } catch {
            print("[pushup] unlock monitor scheduling failed: \(error.localizedDescription)")
        }
    }

    private func stopUnlockMonitor() {
        DeviceActivityCenter().stopMonitoring([unlockMonitorName])
    }

    private func monitorDateComponents(for date: Date) -> DateComponents {
        Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
    }

    private var cameraPermissionDescription: String {
        switch cameraModel.accessState {
        case .denied:
            return "Camera is optional. Turn it on in Settings if you want the app to count real pushup reps."
        case .unavailable:
            return "This device cannot use the front camera. You can still continue without rep tracking."
        case .failed:
            return "Camera setup failed. Try again, or continue without rep tracking for now."
        case .requesting:
            return "Approve camera access when iOS asks."
        case .idle, .granted:
            return "Camera is optional, but it is required if you want the app to verify pushups automatically."
        }
    }

    private var cameraPermissionStatusText: String {
        switch cameraModel.accessState {
        case .denied:
            return "Camera access is off."
        case .unavailable:
            return "No usable front camera."
        case .failed:
            return "Camera could not start."
        case .requesting:
            return "Waiting for permission..."
        case .idle:
            return "Camera permission not granted."
        case .granted:
            return "Camera ready."
        }
    }

    private var notificationPermissionDescription: String {
        switch notificationAuthorizationStatus {
        case .denied:
            return "Notifications are optional. Turn them on in Settings if you want unlock ending reminders."
        case .authorized, .provisional, .ephemeral:
            return "Notifications are ready. You can continue to camera setup."
        case .notDetermined:
            return "Notifications are optional, but they can warn you before protected apps lock again."
        @unknown default:
            return "Notifications are optional. Continue, or enable them if you want reminders."
        }
    }

    private var notificationPermissionStatusText: String {
        switch notificationAuthorizationStatus {
        case .denied:
            return "Notifications are off. You can still continue."
        case .authorized:
            return "Notifications ready."
        case .provisional:
            return "Notifications are provisionally allowed."
        case .ephemeral:
            return "Notifications are temporarily allowed."
        case .notDetermined:
            return "Allow notifications now, or skip this step."
        @unknown default:
            return "Notification status unknown."
        }
    }

    private var notificationPermissionActionTitle: String {
        switch notificationAuthorizationStatus {
        case .denied:
            return "Open Settings"
        case .authorized, .provisional, .ephemeral:
            return "Continue"
        case .notDetermined:
            return isRequestingNotificationPermission ? "Waiting for Permission" : "Continue"
        @unknown default:
            return "Continue"
        }
    }

    private var cameraPermissionActionTitle: String {
        switch cameraModel.accessState {
        case .denied:
            return "Open Settings"
        case .unavailable:
            return "Retry Camera Check"
        case .failed:
            return "Try Camera Again"
        case .requesting:
            return "Waiting for Permission"
        case .idle, .granted:
            return "Continue"
        }
    }

    private func handleCameraPermissionAction() {
        switch cameraModel.accessState {
        case .denied:
            hasAcknowledgedCameraPrompt = true
            openAppSettings()
        case .requesting:
            break
        case .unavailable, .failed, .idle, .granted:
            cameraModel.requestAccessIfNeeded { granted in
                hasAcknowledgedCameraPrompt = true
                if granted {
                    startInitialPushupChallengeIfNeeded()
                } else {
                    completeInitialSetup()
                }
            }
        }
    }

    private func requestNotificationAuthorization() {
        isRequestingNotificationPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            Task { @MainActor in
                isRequestingNotificationPermission = false
                hasAcknowledgedNotificationPrompt = true
                await refreshNotificationAuthorizationStatus()
            }
        }
    }

    private func handleNotificationPermissionAction() {
        switch notificationAuthorizationStatus {
        case .denied:
            openAppSettings()
        case .notDetermined:
            requestNotificationAuthorization()
        case .authorized, .provisional, .ephemeral:
            hasAcknowledgedNotificationPrompt = true
            refreshPermissionStatuses()
        @unknown default:
            hasAcknowledgedNotificationPrompt = true
            refreshPermissionStatuses()
        }
    }

    private func scheduleUnlockNotifications(for endDate: Date) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["unlock-warning", "unlock-ended"])

        let warningInterval = endDate.timeIntervalSinceNow - 30
        if warningInterval > 0 {
            let content = UNMutableNotificationContent()
            content.title = "Time almost up"
            content.body = "Your selected apps lock again in 30 seconds."
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
        print("[pushup] starting app edit challenge")
        showingAppEditIntro = false
        challengeBaselineReps = pushupCount
        showingAppChangeChallenge = true
        isOpeningRepTracker = false
        isTrackingReps = false
        flatSurfaceModel.start()
    }

    private func cancelAppChangeChallenge() {
        print("[pushup] cancel app edit challenge")
        showingAppChangeChallenge = false
        cameraModel.stop()
        flatSurfaceModel.stop()
    }

    private func completeAppChangeChallenge() {
        print("[pushup] completed app edit challenge")
        showingAppChangeChallenge = false
        cameraModel.stop()
        flatSurfaceModel.stop()
        presentAppPicker()
    }

    private func startInitialPushupChallengeIfNeeded() {
        guard !hasCompletedInitialSetup else { return }
        if !hasPreparedOnboardingChallenge {
            onboardingBaselineReps = pushupCount
            hasPreparedOnboardingChallenge = true
        }
        cameraModel.start()
    }

    private func completeInitialSetup() {
        hasCompletedInitialSetup = true
        hasPreparedOnboardingChallenge = false
        cameraModel.stop()
        flatSurfaceModel.stop()
    }

    private func beginMainMenuAdGate() {
        guard !hasShownMainMenuAdGate else { return }

        bannerLoadState.reset()
        showingMainMenuAdGate = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if showingMainMenuAdGate {
                finishMainMenuAdGate()
            }
        }
    }

    private func finishMainMenuAdGate() {
        showingMainMenuAdGate = false
        hasShownMainMenuAdGate = true
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func openPrivacyPolicy() {
        guard let privacyPolicyURL else { return }
        UIApplication.shared.open(privacyPolicyURL)
    }

    private func refreshPermissionStatuses() {
        screenTimeAuthorizationStatus = AuthorizationCenter.shared.authorizationStatus
        print("[pushup] refresh permissions; screenTimeStatus=\(String(describing: screenTimeAuthorizationStatus))")
        cameraModel.refreshAuthorizationStatus()

        Task { @MainActor in
            await refreshNotificationAuthorizationStatus()
        }
    }

    @MainActor
    private func refreshNotificationAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAuthorizationStatus = settings.authorizationStatus
        print("[pushup] notification status -> \(notificationAuthorizationStatus.rawValue)")
    }

    private var notificationsAreEnabled: Bool {
        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    private var screenTimePermissionGranted: Bool {
        switch screenTimeAuthorizationStatus {
        case .approved, .approvedWithDataAccess:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    private var cameraPermissionGranted: Bool {
        if case .granted = cameraModel.accessState {
            return true
        }
        return false
    }

    private var screenTimePermissionLabel: String {
        switch screenTimeAuthorizationStatus {
        case .approved:
            return "Allowed"
        case .approvedWithDataAccess:
            return "Allowed + Data"
        case .denied:
            return "Denied"
        case .notDetermined:
            return "Not Asked"
        @unknown default:
            return "Unknown"
        }
    }

    private var notificationPermissionLabel: String {
        switch notificationAuthorizationStatus {
        case .authorized:
            return "Allowed"
        case .provisional:
            return "Provisional"
        case .ephemeral:
            return "Ephemeral"
        case .denied:
            return "Denied"
        case .notDetermined:
            return "Not Asked"
        @unknown default:
            return "Unknown"
        }
    }

    private var cameraPermissionLabel: String {
        switch cameraModel.accessState {
        case .granted:
            return "Allowed"
        case .requesting:
            return "Waiting"
        case .denied:
            return "Denied"
        case .idle:
            return "Not Asked"
        case .unavailable:
            return "Unavailable"
        case .failed:
            return "Failed"
        }
    }

    private var themeBackground: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.backgroundTop, AppTheme.backgroundMid, AppTheme.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )

            Circle()
                .fill(AppTheme.sky.opacity(0.18))
                .frame(width: 240, height: 240)
                .blur(radius: 42)
                .offset(x: 115, y: -240)

            Circle()
                .fill(AppTheme.heroGlow.opacity(0.28))
                .frame(width: 210, height: 210)
                .blur(radius: 36)
                .offset(y: 250)

            Circle()
                .fill(AppTheme.lime.opacity(0.12))
                .frame(width: 190, height: 190)
                .blur(radius: 40)
                .offset(x: -120, y: 180)

            ArcBandShape()
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.03), AppTheme.sky.opacity(0.10), Color.white.opacity(0.025)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 22, lineCap: .round)
                )
                .frame(width: 420, height: 420)
                .offset(x: -170, y: -150)

            ArcBandShape()
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.02), AppTheme.lime.opacity(0.07), Color.white.opacity(0.02)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 16, lineCap: .round)
                )
                .frame(width: 320, height: 320)
                .offset(x: 160, y: -10)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.black.opacity(0.08), Color.black.opacity(0.24)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .ignoresSafeArea()
    }
}

private enum AppTheme {
    static let backgroundTop = Color(red: 0.04, green: 0.23, blue: 0.47)
    static let backgroundMid = Color(red: 0.06, green: 0.37, blue: 0.42)
    static let backgroundBottom = Color(red: 0.03, green: 0.16, blue: 0.12)
    static let accent = Color(red: 0.63, green: 0.95, blue: 0.34)
    static let accentBright = Color(red: 0.92, green: 1.00, blue: 0.63)
    static let sky = Color(red: 0.31, green: 0.78, blue: 0.97)
    static let lime = Color(red: 0.63, green: 0.93, blue: 0.38)
    static let gold = Color(red: 0.98, green: 0.83, blue: 0.26)
    static let heroGlow = Color(red: 0.98, green: 0.93, blue: 0.35)
    static let panelTint = Color(red: 0.03, green: 0.15, blue: 0.18).opacity(0.56)
    static let softTint = Color(red: 0.09, green: 0.31, blue: 0.34).opacity(0.44)
    static let secondaryText = Color.white.opacity(0.80)
}

private struct LiquidGlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color
    let padding: CGFloat
    let expandsHorizontally: Bool

    func body(content: Content) -> some View {
        Group {
            if expandsHorizontally {
                content
                    .padding(padding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                content
                    .padding(padding)
            }
        }
        .modifier(LiquidGlassBackgroundModifier(cornerRadius: cornerRadius, tint: tint, interactive: false))
    }
}

private struct LiquidGlassBackgroundModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let glass = interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint)
            content
                .glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.24), radius: 22, y: 12)
        } else {
            content
                .background(
                    LinearGradient(
                        colors: [tint.opacity(0.98), tint.opacity(0.88)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.22), AppTheme.sky.opacity(0.16), Color.black.opacity(0.16)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: AppTheme.heroGlow.opacity(0.06), radius: 10, y: 6)
                .shadow(color: Color.black.opacity(0.24), radius: 20, y: 12)
        }
    }
}

private struct ArcBandShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) * 0.44,
            startAngle: .degrees(155),
            endAngle: .degrees(328),
            clockwise: false
        )
        return path
    }
}

private extension View {
    func liquidGlassPanel(
        cornerRadius: CGFloat,
        tint: Color,
        padding: CGFloat = 20,
        expandsHorizontally: Bool = true
    ) -> some View {
        modifier(
            LiquidGlassPanelModifier(
                cornerRadius: cornerRadius,
                tint: tint,
                padding: padding,
                expandsHorizontally: expandsHorizontally
            )
        )
    }

    func liquidGlassButtonBackground(
        cornerRadius: CGFloat,
        tint: Color,
        interactive: Bool = true
    ) -> some View {
        modifier(LiquidGlassBackgroundModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    func liquidGlassCapsuleButton(tint: Color) -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .modifier(LiquidGlassBackgroundModifier(cornerRadius: 999, tint: tint, interactive: true))
    }
}

#Preview {
    ContentView()
}
