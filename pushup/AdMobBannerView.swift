import Combine
import SwiftUI

#if canImport(GoogleMobileAds)
import GoogleMobileAds
import UIKit

struct AdMobBannerContainer: UIViewControllerRepresentable {
    let adUnitID: String

    func makeUIViewController(context: Context) -> BannerHostingController {
        let controller = BannerHostingController()
        controller.adUnitID = adUnitID
        return controller
    }

    func updateUIViewController(_ uiViewController: BannerHostingController, context: Context) {
        uiViewController.adUnitID = adUnitID
        uiViewController.loadAdIfNeeded()
    }
}

@MainActor
final class BannerLoadState: ObservableObject {
    static let shared = BannerLoadState()

    @Published private(set) var isLoaded = false

    private init() {}

    func reset() {
        isLoaded = false
    }

    func markLoaded() {
        isLoaded = true
    }
}

final class BannerHostingController: UIViewController, BannerViewDelegate {
    var adUnitID = ""

    private var bannerView: BannerView?
    private var loadedUnitID: String?
    private var lastLoadedWidth: CGFloat = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    func loadAdIfNeeded() {
        guard !adUnitID.isEmpty else { return }
        let size = currentAdSize()
        let widthChanged = abs(size.size.width - lastLoadedWidth) > 1
        guard loadedUnitID != adUnitID || bannerView == nil || widthChanged else { return }

        print("[admob] preparing banner for unit \(adUnitID)")
        bannerView?.removeFromSuperview()

        print("[admob] requesting banner size \(size.size.width)x\(size.size.height)")
        let banner = BannerView(adSize: size)
        banner.adUnitID = adUnitID
        banner.rootViewController = self
        banner.delegate = self
        banner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(banner)

        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            banner.topAnchor.constraint(equalTo: view.topAnchor),
            banner.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        banner.load(Request())
        bannerView = banner
        loadedUnitID = adUnitID
        lastLoadedWidth = size.size.width
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = currentAdSize()

        if let bannerView, abs(size.size.width - lastLoadedWidth) > 1 {
            print("[admob] width changed; refreshing banner to \(size.size.width)x\(size.size.height)")
            bannerView.removeFromSuperview()
            self.bannerView = nil
            loadedUnitID = nil
            loadAdIfNeeded()
            return
        }

        print("[admob] layout width=\(view.bounds.width) height=\(view.bounds.height) banner=\(size.size.width)x\(size.size.height)")
    }

    private func currentAdSize() -> AdSize {
        let width = max(view.bounds.width, 320)
        return currentOrientationAnchoredAdaptiveBanner(width: width)
    }

    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        print("[admob] banner loaded successfully")
        BannerLoadState.shared.markLoaded()
    }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        print("[admob] banner failed to load: \(error.localizedDescription)")
    }

    func bannerViewDidRecordImpression(_ bannerView: BannerView) {
        print("[admob] banner recorded impression")
    }

    func bannerViewDidRecordClick(_ bannerView: BannerView) {
        print("[admob] banner recorded click")
    }
}

@MainActor
final class RewardedAdManager: NSObject, ObservableObject, FullScreenContentDelegate {
    @Published private(set) var isLoading = false
    @Published private(set) var isReady = false
    @Published var lastErrorMessage: String?

    private var rewardedAd: RewardedAd?
    private var loadedAdUnitID: String?
    private var pendingRewardAction: (() -> Void)?

    func preload(adUnitID: String) {
        guard !adUnitID.isEmpty else { return }
        guard !isLoading else { return }
        guard rewardedAd == nil || loadedAdUnitID != adUnitID else { return }

        Task {
            await loadAd(adUnitID: adUnitID)
        }
    }

    func showAd(adUnitID: String, onReward: @escaping () -> Void) {
        guard !adUnitID.isEmpty else {
            lastErrorMessage = "Rewarded ads are not configured yet."
            return
        }

        pendingRewardAction = onReward

        Task {
            if rewardedAd == nil || loadedAdUnitID != adUnitID {
                await loadAd(adUnitID: adUnitID)
            }

            guard let rewardedAd else { return }
            guard let rootViewController = Self.topViewController() else {
                lastErrorMessage = "Couldn't open the rewarded ad."
                return
            }

            lastErrorMessage = nil
            rewardedAd.present(from: rootViewController) { [weak self] in
                self?.pendingRewardAction?()
                self?.pendingRewardAction = nil
            }
        }
    }

    private func loadAd(adUnitID: String) async {
        guard !isLoading else { return }

        isLoading = true
        lastErrorMessage = nil

        do {
            let rewardedAd = try await RewardedAd.load(with: adUnitID, request: Request())
            rewardedAd.fullScreenContentDelegate = self
            self.rewardedAd = rewardedAd
            loadedAdUnitID = adUnitID
            isReady = true
            print("[admob] rewarded ad loaded")
        } catch {
            rewardedAd = nil
            loadedAdUnitID = nil
            isReady = false
            lastErrorMessage = error.localizedDescription
            print("[admob] rewarded ad failed to load: \(error.localizedDescription)")
        }

        isLoading = false
    }

    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        print("[admob] rewarded ad dismissed")
        rewardedAd = nil
        isReady = false
        if let loadedAdUnitID {
            preload(adUnitID: loadedAdUnitID)
        }
    }

    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        print("[admob] rewarded ad failed to present: \(error.localizedDescription)")
        rewardedAd = nil
        isReady = false
        lastErrorMessage = error.localizedDescription
        pendingRewardAction = nil
    }

    @MainActor
    private static func topViewController(
        base: UIViewController? = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .rootViewController
    ) -> UIViewController? {
        if let navigationController = base as? UINavigationController {
            return topViewController(base: navigationController.visibleViewController)
        }

        if let tabBarController = base as? UITabBarController {
            return topViewController(base: tabBarController.selectedViewController)
        }

        if let presentedViewController = base?.presentedViewController {
            return topViewController(base: presentedViewController)
        }

        return base
    }
}

#else

struct AdMobBannerContainer: View {
    let adUnitID: String

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .frame(height: 60)
            .overlay {
                Text("Ad banner ready once Google Mobile Ads SDK is added.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
    }
}

@MainActor
final class RewardedAdManager: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var isReady = false
    @Published var lastErrorMessage: String?

    func preload(adUnitID: String) {}

    func showAd(adUnitID: String, onReward: @escaping () -> Void) {
        lastErrorMessage = "Google Mobile Ads SDK is not available."
    }
}

#endif
