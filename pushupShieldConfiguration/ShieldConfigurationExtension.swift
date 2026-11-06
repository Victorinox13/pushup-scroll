import ManagedSettings
import ManagedSettingsUI
import UIKit

final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        let appName = application.localizedDisplayName ?? "this app"
        let quote = shieldQuote(for: appName)

        return ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterialDark,
            backgroundColor: UIColor(red: 0.09, green: 0.10, blue: 0.14, alpha: 0.94),
            icon: UIImage(systemName: "figure.strengthtraining.traditional"),
            title: ShieldConfiguration.Label(
                text: "RepCoin Pause",
                color: .white
            ),
            subtitle: ShieldConfiguration.Label(
                text: "\"\(quote)\" Open RepCoin, earn a few pushups, then come back to \(appName).",
                color: UIColor.white.withAlphaComponent(0.78)
            ),
            primaryButtonLabel: ShieldConfiguration.Label(
                text: "Notify Me in RepCoin",
                color: .white
            ),
            primaryButtonBackgroundColor: UIColor(red: 0.97, green: 0.47, blue: 0.20, alpha: 1),
            secondaryButtonLabel: ShieldConfiguration.Label(
                text: "Close",
                color: UIColor.white.withAlphaComponent(0.82)
            )
        )
    }

    private func shieldQuote(for appName: String) -> String {
        let quotes = [
            "A few pushups cost less than another lost hour",
            "Scroll feels better when you earn it first",
            "Trade one craving for one clean set",
            "Momentum beats mindless minutes",
            "Win your attention back before \(appName) takes it"
        ]

        let index = abs(appName.hashValue) % quotes.count
        return quotes[index]
    }
}
