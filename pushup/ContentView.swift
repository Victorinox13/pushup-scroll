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
                statusText: calibrationSamples >= calibrationTarget ? "Start." : "Hold at top.",
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
                    statusText: "Push up.",
                    progress: 1,
                    didCompleteRep: false,
                    faceDetected: true
                )
            }

            return PushupDetectorUpdate(
                statusText: "Lower down.",
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
                    statusText: "Rep done.",
                    progress: 0,
                    didCompleteRep: true,
                    faceDetected: true
                )
            }

            return PushupDetectorUpdate(
                statusText: "Go higher.",
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
    @State private var showingLaunchScreen = true
    @State private var onboardingBaselineReps = 0
    @State private var hasPreparedOnboardingChallenge = false
    @State private var showingPermissionStatusSheet = false
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var screenTimeAuthorizationStatus: AuthorizationStatus = .notDetermined
    @State private var isRequestingNotificationPermission = false
    @State private var isRequestingScreenTimePermission = false
    @State private var isOpeningRepTracker = false

    private let shieldStore = ManagedSettingsStore(named: .init("pushup.shield"))
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let appChangeChallengeTarget = 5
    private let introChallengeTarget = 5

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

    private var onboardingStage: OnboardingStage? {
        if showingLaunchScreen || !hasLoadedSelection {
            return .loading
        }

        guard !hasCompletedInitialSetup else { return nil }

        if selectedAppsCount == 0 {
            return .appSelection
        }

        guard notificationsAreEnabled else {
            return .notificationPermission
        }

        switch cameraModel.accessState {
        case .granted:
            return .introChallenge
        case .idle, .requesting, .denied, .unavailable, .failed:
            return .cameraPermission
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
            } else if isTrackingReps {
                repTrackerOverlay
            }
        }
        .onAppear {
            print("[pushup] content view appeared")
            cameraModel.onRepCounted = {
                pushupCount += 1
                print("[pushup] rep counted; total=\(pushupCount)")
                if !hasCompletedInitialSetup,
                   onboardingCompletedReps >= introChallengeTarget {
                    completeInitialSetup()
                }
                if showingAppChangeChallenge, challengeCompletedReps >= appChangeChallengeTarget {
                    completeAppChangeChallenge()
                }
            }
            startInitialLoad()
        }
        .onDisappear {
            print("[pushup] content view disappeared")
            cameraModel.stop()
        }
        .onChange(of: familyActivitySelection) {
            guard hasLoadedSelection else { return }
            print("[pushup] family activity selection changed; apps=\(familyActivitySelection.applicationTokens.count) categories=\(familyActivitySelection.categoryTokens.count) domains=\(familyActivitySelection.webDomainTokens.count)")
            persistSelection()
            applyShields()
            if !hasCompletedInitialSetup, selectedAppsCount > 0 {
                cameraModel.refreshAuthorizationStatus()
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
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                print("[pushup] scene became active")
                refreshUnlockState()
                refreshPermissionStatuses()
            }
        }
        .onReceive(timer) { _ in
            currentTime = Date()
            refreshUnlockState()
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
        VStack(spacing: 24) {
            Spacer()

            VStack(alignment: .leading, spacing: 20) {
                Text("pushup")
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text("Preparing your focus lock.")
                    .font(.system(.title3, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)

                ProgressView()
                    .tint(AppTheme.accent)
            }
            .liquidGlassPanel(cornerRadius: 30, tint: AppTheme.panelTint)

            Spacer()
        }
        .padding(20)
    }

    private var initialAppSelectionView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(alignment: .leading, spacing: 18) {
                Text("Lock in your blockers")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

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

            Spacer()
        }
        .padding(20)
    }

    private var notificationPermissionView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(alignment: .leading, spacing: 18) {
                Text("Allow notifications")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

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

            Spacer()
        }
        .padding(20)
    }

    private var cameraPermissionView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(alignment: .leading, spacing: 18) {
                Text("Allow the camera")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text(cameraPermissionDescription)
                    .font(.system(.title3, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)

                cameraPlaceholder(text: cameraPermissionStatusText)

                quickButton(title: cameraPermissionActionTitle) {
                    handleCameraPermissionAction()
                }
            }
            .liquidGlassPanel(cornerRadius: 30, tint: AppTheme.panelTint)

            Spacer()
        }
        .padding(20)
    }

    private var introChallengeView: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 18) {
                Text("Earn your start")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

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

            Text("Real reps only. The front camera watches how close you come to the phone and counts a pushup after a full down-and-up motion.")
                .font(.system(.body, design: .rounded))
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
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        showingSpendOptions.toggle()
                    }
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
                Text("Unlocked for \(formattedUnlockTime)")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            if showingSpendOptions {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Buy minutes")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryText)

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
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            HStack(spacing: 12) {
                statPill(title: "Reps", value: "\(pushupCount)")
                statPill(title: "Rotted", value: "\(unlockedMinutes)m")
                statPill(title: "Spent", value: "\(spentReps)")
            }
        }
        .liquidGlassPanel(cornerRadius: 28, tint: AppTheme.panelTint)
    }

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Rep Arena")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()
            }

            Text(isTrackingReps ? "Arena open. Keep your form clean." : "Open a focused training popup with live cues and a square camera view.")
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
                    Text("Opening camera...")
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
                    Text("Protected Apps")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.white)

                    Text("\(selectedAppsCount) protected items")
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

            HStack(spacing: 10) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(AppTheme.gold)
                Text("Need 5 pushups to edit your lock list.")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            if let appPickerError {
                Text(appPickerError)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .liquidGlassPanel(cornerRadius: 28, tint: AppTheme.panelTint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var repTrackerOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture {
                    closeRepTracker()
                }

            VStack(alignment: .leading, spacing: 18) {
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

                trackerCameraSurface

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle()
                            .fill(cameraModel.faceDetected ? AppTheme.accentBright : Color.white.opacity(0.35))
                            .frame(width: 10, height: 10)
                        Text(cameraModel.statusText)
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(AppTheme.secondaryText)
                    }

                    ProgressView(value: cameraModel.repProgress)
                        .tint(AppTheme.accent)

                    HStack(spacing: 10) {
                        trackerStatBadge(title: "Score", value: "\(pushupCount)")
                        trackerStatBadge(title: "Coins", value: "\(bank.repCoins)")
                    }
                }
            }
            .liquidGlassPanel(cornerRadius: 28, tint: AppTheme.panelTint)
            .padding(20)
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

            VStack(alignment: .leading, spacing: 18) {
                Text("Unlock Edit Mode")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text("Hit 5 clean pushups to earn one edit to your protected apps.")
                    .font(.system(.title3, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))

                trackerCameraSurface

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
                    .liquidGlassCapsuleButton(tint: .white.opacity(0.18))
                }

                ProgressView(value: Double(challengeCompletedReps), total: Double(appChangeChallengeTarget))
                    .tint(AppTheme.accent)

                HStack {
                    Circle()
                        .fill(cameraModel.faceDetected ? AppTheme.accentBright : Color.white.opacity(0.35))
                        .frame(width: 10, height: 10)
                    Text(cameraModel.statusText)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryText)
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
                    detail: "Used for unlock ending reminders."
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
        ZStack(alignment: .top) {
            Group {
                switch cameraModel.accessState {
                case .granted, .idle:
                    CameraPreviewView(session: cameraModel.session)
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
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            VStack(spacing: 10) {
                Text(trackerCueText)
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .liquidGlassButtonBackground(cornerRadius: 18, tint: AppTheme.accent.opacity(0.34), interactive: false)

                Text(cameraModel.sessionRunning ? "Stay centered and follow the cue." : "Camera warming up.")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .liquidGlassButtonBackground(cornerRadius: 16, tint: AppTheme.softTint, interactive: false)
            }
            .padding(.top, 14)

            VStack {
                Spacer()
                HStack {
                    Text(cameraModel.sessionRunning ? "LIVE" : "STARTING")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .liquidGlassButtonBackground(cornerRadius: 999, tint: AppTheme.softTint, interactive: false)
                    Spacer()
                }
                .padding(14)
            }
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

    private var trackerCueText: String {
        let text = cameraModel.statusText.lowercased()
        if text.contains("lower") || text.contains("down") {
            return "DOWN"
        }
        if text.contains("push") || text.contains("higher") || text.contains("rep done") || text.contains("top") {
            return "UP"
        }
        if text.contains("frame") {
            return "LOCK IN"
        }
        return "READY"
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
        beginAppChangeChallenge()
    }

    private func openRepTracker() {
        guard !isTrackingReps, !isOpeningRepTracker else { return }
        print("[pushup] opening rep tracker")
        isOpeningRepTracker = true
        isTrackingReps = true
        cameraModel.start()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            isOpeningRepTracker = false
        }
    }

    private func closeRepTracker() {
        print("[pushup] closing rep tracker")
        isOpeningRepTracker = false
        isTrackingReps = false
        cameraModel.stop()
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

    private var cameraPermissionDescription: String {
        switch cameraModel.accessState {
        case .denied:
            return "Turn camera access on in Settings to continue."
        case .unavailable:
            return "A front camera is required to verify reps."
        case .failed:
            return "Try camera access again, then finish 5 pushups."
        case .requesting:
            return "Approve camera access when iOS asks."
        case .idle, .granted:
            return "Allow camera access to verify your first 5 pushups."
        }
    }

    private var notificationPermissionDescription: String {
        switch notificationAuthorizationStatus {
        case .denied:
            return "Turn notifications on in Settings so the app can warn you before your unlock ends."
        case .authorized, .provisional, .ephemeral:
            return "Notifications are ready. Continue if you already allowed them."
        case .notDetermined:
            return "Allow notifications so you get a warning before protected apps lock again."
        @unknown default:
            return "Check notification access to continue."
        }
    }

    private var notificationPermissionStatusText: String {
        switch notificationAuthorizationStatus {
        case .denied:
            return "Notifications are off."
        case .authorized:
            return "Notifications ready."
        case .provisional:
            return "Notifications are provisionally allowed."
        case .ephemeral:
            return "Notifications are temporarily allowed."
        case .notDetermined:
            return "Notification permission not granted."
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
            return isRequestingNotificationPermission ? "Waiting for Permission" : "Allow Notifications"
        @unknown default:
            return "Check Notifications"
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
            return "Allow Camera"
        }
    }

    private func handleCameraPermissionAction() {
        switch cameraModel.accessState {
        case .denied:
            openAppSettings()
        case .requesting:
            break
        case .unavailable, .failed, .idle, .granted:
            cameraModel.requestAccessIfNeeded { granted in
                if granted {
                    startInitialPushupChallengeIfNeeded()
                }
            }
        }
    }

    private func requestNotificationAuthorization() {
        isRequestingNotificationPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            Task { @MainActor in
                isRequestingNotificationPermission = false
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
            refreshPermissionStatuses()
        @unknown default:
            refreshPermissionStatuses()
        }
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
        print("[pushup] starting app edit challenge")
        challengeBaselineReps = pushupCount
        showingAppChangeChallenge = true
        isOpeningRepTracker = false
        isTrackingReps = false
        cameraModel.start()
    }

    private func cancelAppChangeChallenge() {
        print("[pushup] cancel app edit challenge")
        showingAppChangeChallenge = false
        cameraModel.stop()
    }

    private func completeAppChangeChallenge() {
        print("[pushup] completed app edit challenge")
        showingAppChangeChallenge = false
        cameraModel.stop()
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
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
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
                colors: [AppTheme.backgroundTop, AppTheme.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(AppTheme.accent.opacity(0.22))
                .frame(width: 360, height: 360)
                .blur(radius: 70)
                .offset(x: 140, y: -260)

            Circle()
                .fill(AppTheme.accentBright.opacity(0.18))
                .frame(width: 280, height: 280)
                .blur(radius: 60)
                .offset(x: -150, y: 260)

            Rectangle()
                .fill(.black.opacity(0.18))
        }
        .ignoresSafeArea()
    }
}

private enum AppTheme {
    static let backgroundTop = Color(red: 0.05, green: 0.08, blue: 0.13)
    static let backgroundBottom = Color(red: 0.01, green: 0.03, blue: 0.07)
    static let accent = Color(red: 0.34, green: 0.72, blue: 0.82)
    static let accentBright = Color(red: 0.56, green: 0.86, blue: 0.87)
    static let gold = Color(red: 0.96, green: 0.76, blue: 0.30)
    static let panelTint = Color.white.opacity(0.08)
    static let softTint = Color.white.opacity(0.10)
    static let secondaryText = Color.white.opacity(0.74)
}

private struct LiquidGlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        } else {
            content
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                }
        }
    }
}

private extension View {
    func liquidGlassPanel(cornerRadius: CGFloat, tint: Color, padding: CGFloat = 20) -> some View {
        modifier(LiquidGlassPanelModifier(cornerRadius: cornerRadius, tint: tint, padding: padding))
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
