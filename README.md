# pushup-scroll

`pushup-scroll` is a SwiftUI app that turns pushups into unlock time.

The app lets you:
- Pick apps and websites to protect with Screen Time.
- Earn rep coins by doing real pushups with camera-based rep tracking.
- Spend rep coins to unlock your protected apps for a limited time.
- Require a 5-pushup challenge before editing the protected app list.

## Stack

- SwiftUI
- FamilyControls
- ManagedSettings
- AVFoundation
- Vision
- UserNotifications

## Current Flow

1. Choose the apps or websites to protect.
2. Allow notifications.
3. Allow camera access.
4. Finish the onboarding pushup challenge.
5. Use the rep tracker to earn coins and buy unlock time.

Editing the protected app list is gated behind a 5-pushup popup challenge.

## Running

Open `pushup.xcodeproj` in Xcode and run the app on a real iPhone.

Notes:
- Camera-based tracking does not work in the iOS Simulator.
- Screen Time / FamilyControls requires the correct entitlement and a supported device/account setup.
- Notifications must be enabled if you want unlock reminders.

## Repo Notes

- App icon assets are generated from `pushup/icontouse.png`.
- Main app logic currently lives mostly in `pushup/ContentView.swift`.

