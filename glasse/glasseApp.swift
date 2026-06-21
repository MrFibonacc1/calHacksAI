//
//  glasseApp.swift
//  glasse
//

import SwiftUI
import MWDATCore

@main
struct glasseApp: App {
    init() {
        Telemetry.start()   // reliability/observability from launch (no-op without a DSN)
        // Configure the Meta Wearables Device Access Toolkit once at launch.
        do {
            try Wearables.configure()
        } catch {
            print("[glasse] Wearables.configure() failed: \(error)")
            Telemetry.capture(error, ["phase": "wearables.configure"])
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Shows the onboarding intro on first launch, then the main screen.
struct RootView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    var body: some View {
        if hasOnboarded {
            ContentView()
        } else {
            OnboardingView { hasOnboarded = true }
        }
    }
}
