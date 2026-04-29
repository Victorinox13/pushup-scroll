import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

final class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    private let sharedDefaultsSuiteName = "group.deleeck.pushtounrot.shared"
    private let sharedSelectionKey = "screenTimeSelectionData"
    private let sharedUnlockEndsAtKey = "unlockEndsAt"
    private let unlockMonitorName = DeviceActivityName("deleeck.pushtounrot.unlock-monitor")
    private let shieldStore = ManagedSettingsStore(named: .init("pushup.shield"))

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)

        guard activity == unlockMonitorName else { return }
        applyStoredShields()
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)

        guard activity == unlockMonitorName else { return }
        applyStoredShields()
    }

    private func applyStoredShields() {
        guard let sharedDefaults = UserDefaults(suiteName: sharedDefaultsSuiteName) else { return }

        defer {
            sharedDefaults.set(0, forKey: sharedUnlockEndsAtKey)
            DeviceActivityCenter().stopMonitoring([unlockMonitorName])
        }

        guard let encodedSelection = sharedDefaults.string(forKey: sharedSelectionKey),
              let data = Data(base64Encoded: encodedSelection),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            shieldStore.clearAllSettings()
            return
        }

        shieldStore.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        shieldStore.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
        shieldStore.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
        shieldStore.shield.webDomainCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
    }
}
