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

final class BannerHostingController: UIViewController, BannerViewDelegate {
    var adUnitID = ""

    private var bannerView: BannerView?
    private var loadedUnitID: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    func loadAdIfNeeded() {
        guard !adUnitID.isEmpty else { return }
        guard loadedUnitID != adUnitID || bannerView == nil else { return }

        bannerView?.removeFromSuperview()

        let size = currentAdSize()
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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        bannerView?.adSize = currentAdSize()
    }

    private func currentAdSize() -> AdSize {
        let width = max(view.bounds.width, 320)
        return currentOrientationAnchoredAdaptiveBanner(width: width)
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

#endif

