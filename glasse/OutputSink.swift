//
//  OutputSink.swift
//  glasse
//
//  Modality-specific delivery of a result. The text is always shown on the
//  phone; the sink adds the agent's chosen output channel on top: speech,
//  on-screen (with a VoiceOver announcement), or the in-lens display.
//

import Foundation
import UIKit

/// Posts a VoiceOver announcement so blind users hear screen-only results.
@MainActor
func announce(_ text: String) {
    guard !text.isEmpty else { return }
    UIAccessibility.post(notification: .announcement, argument: text)
}

@MainActor
protocol OutputSink {
    func deliver(_ text: String)
}

/// Speaks the text aloud (routes to the glasses' open-ear speaker over Bluetooth).
@MainActor
struct SpeechSink: OutputSink {
    let speaker: Speaker
    func deliver(_ text: String) { speaker.speak(text) }
}

/// Text is shown large on the phone screen and announced to VoiceOver.
@MainActor
struct ScreenSink: OutputSink {
    func deliver(_ text: String) { announce(text) }
}
