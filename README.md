# Karv

A sleek, dark-first iOS app + macOS menu bar companion for tracking your **Claude**, **Codex**, and **Gemini** subscription usage and reset countdowns.

## Architecture

- **`Packages/KarvCore`**: Shared Swift 6 package containing models (`AIProvider`, `QuotaWindow`, `ProviderUsageSnapshot`, `KarvSnapshot`), live countdown formatting, demo snapshot data, and `KarvSyncStore` (iCloud Key-Value Store + App Group cache).
- **`Apps/KarvIOS`**: Native SwiftUI iPhone app (iOS 18+) with a Linear/Raycast-inspired dark minimalist UI, live ticking reset timers, Swift Charts 7-day trends, detail sheets with manual override, and sync settings.
- **`Apps/KarvWidget`**: WidgetKit extension providing Home Screen (small & medium) and Lock Screen (`accessoryRectangular` & `accessoryCircular`) widgets.
- **`Apps/KarvMac`**: Lightweight macOS menu bar companion (`LSUIElement`) that inspects local `~/.claude`, `~/.codex`, and `~/.gemini` directories every 5 minutes and publishes snapshots to iCloud for your iPhone.

## Getting Started

1. Open `Karv.xcodeproj` in Xcode (or regenerate it anytime via `xcodegen generate`).
2. Select your **Apple Developer Team** under **Signing & Capabilities** for all three targets (`Karv`, `KarvWidget`, `KarvMac`).
3. Ensure **iCloud (Key-Value Storage)** and **App Groups (`group.com.karv.shared`)** are enabled for your team/bundle IDs.
4. Run **`Karv`** on your iPhone (or iOS Simulator) — Demo Preview Mode is enabled by default so you can explore the full UI immediately.
5. Run **`KarvMac`** on your Mac to start syncing live local CLI usage to your iPhone, then turn off **Demo preview mode** in Karv's **Sync** tab.
