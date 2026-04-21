//
//  pushupApp.swift
//  pushup
//
//  Created by Victor Deleeck on 11/04/2026.
//

import SwiftUI
#if canImport(GoogleMobileAds)
import GoogleMobileAds
#endif

@main
struct pushupApp: App {
    init() {
        #if canImport(GoogleMobileAds)
        #if DEBUG
        MobileAds.shared.requestConfiguration.testDeviceIdentifiers = [
            "c95d8fa0020c8e0586ff2b808d17a328"
        ]
        #endif
        MobileAds.shared.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
