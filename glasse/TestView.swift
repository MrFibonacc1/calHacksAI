//
//  TestView.swift
//  glasse
//
//  A diagnostics screen: play sample audio into the glasses (Deepgram vs Apple),
//  push a test caption to the lens, and run live captions with an engine
//  indicator — so you can verify the voice + display pipeline in one place.
//

import SwiftUI
import AVFoundation

struct TestView: View {
    let speaker: Speaker
    let captioner: SpeechCaptioner
    let glassesLinked: Bool
    let onSendToLens: (String, String) -> Void
    let onSendSignToLens: (LensVisual) -> Void
    let lensStatus: () -> String

    @Environment(\.dismiss) private var dismiss
    @State private var dgTTS = DeepgramTTS()
    @State private var appleSynth = AVSpeechSynthesizer()
    @State private var sampleText = "Hello — this is a test from Glasses Assist."
    @State private var ttsResult = "Not run yet."
    @State private var capsRunning = false
    @State private var sentryResult = "Not run yet."
    @State private var signResult = "Not run yet."

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    ttsCard
                    lensCard
                    signCard
                    captionsCard
                    sentryCard
                }
                .padding()
            }
            .navigationTitle("Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { if capsRunning { captioner.stop() }; dismiss() }
                }
            }
        }
    }

    // MARK: Status

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Status")
                statusRow("Deepgram key", Deepgram.hasKey ? "Set" : "Missing — Apple fallback", ok: Deepgram.hasKey)
                statusRow("Glasses link", glassesLinked ? "Connected" : "Not connected", ok: glassesLinked)
                Text("Tip: audio plays through the glasses only when they're your Bluetooth audio output.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Voice (TTS)

    private var ttsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Voice in your ear (text-to-speech)")
                TextField("Text to speak", text: $sampleText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)

                Button("▶︎ Play with Deepgram (Aura)") {
                    Task {
                        AudioCoordinator.shared.beginPlayback()
                        let ok = await dgTTS.speak(sampleText)
                        ttsResult = ok
                            ? "Played via Deepgram Aura ✓ — you should hear it in the glasses."
                            : "Deepgram: \(dgTTS.lastStatus). The app would use Apple here."
                    }
                }
                .buttonStyle(SecondaryButtonStyle())

                Button("▶︎ Play with Apple voice") {
                    AudioCoordinator.shared.beginPlayback()
                    dgTTS.stop()
                    appleSynth.stopSpeaking(at: .immediate)
                    appleSynth.speak(AVSpeechUtterance(string: sampleText))
                    ttsResult = "Played via Apple voice — compare the sound to Aura."
                }
                .buttonStyle(SecondaryButtonStyle())

                Button("▶︎ Play via the app (normal path)") {
                    speaker.speak(sampleText)
                    ttsResult = "Played via the app's Speaker (Deepgram first, Apple fallback)."
                }
                .buttonStyle(SecondaryButtonStyle())

                Text(ttsResult).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Lens (display)

    private var lensCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Captions on the lens (display)")
                Button("Send test caption to lens") {
                    onSendToLens("Test caption", "If you can read this on your glasses, the display works.")
                }
                .buttonStyle(SecondaryButtonStyle())
                Text("Display: \(lensStatus())")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Sign language (on the lens)

    /// A few example signs pushed to the lens so you can verify sign content renders
    /// on the glasses. These are whole-word how-to cards (the app fingerspells the
    /// rest); once the ASL handshape images / sign clips are hosted, `SignAssets`
    /// upgrades these to image/video on the lens automatically.
    /// Words that now have a real ASL still image (Wikimedia, CC BY-SA — see
    /// ASL_IMAGE_CREDITS.md). The button pushes each as an `.image` to the lens via
    /// SignAssets.wordVisual; a word without an image falls back to its how-to text.
    private let demoSignWords = ["HELLO", "THANKS", "YES", "NO", "PLEASE", "NAME", "ILY"]

    private var signCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Sign language on the lens")
                Button("▶︎ Show sample signs on lens") {
                    let words = demoSignWords
                    signResult = "Sending \(words.count) signs to the lens…"
                    Task {
                        for w in words {
                            onSendSignToLens(SignAssets.wordVisual(for: w))
                            try? await Task.sleep(nanoseconds: 2_500_000_000)   // ~2.5s dwell per sign
                        }
                        signResult = "Sent \(words.count) signs — watch your glasses (one every ~2.5s)."
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                Text(signResult).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Lens only (display module + real glasses). 7 words now show a real ASL image (Wikimedia, CC BY-SA — see ASL_IMAGE_CREDITS.md); others fall back to how-to text. A still can't show motion, so each carries its how-to as the caption.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Live captions (STT)

    private var captionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Live captions (speech-to-text)")
                Button(capsRunning ? "Stop captions" : "Start test captions") {
                    if capsRunning {
                        captioner.stop(); capsRunning = false
                    } else {
                        capsRunning = true
                        Task {
                            await captioner.start(onUpdate: { _, _ in })
                            if !captioner.isRunning { capsRunning = false }
                        }
                    }
                }
                .buttonStyle(SecondaryButtonStyle(tint: capsRunning ? .red : .accentColor))

                Text("Engine: " + (captioner.usingDeepgram
                                   ? "Deepgram Nova-3 (diarized) ✓"
                                   : (captioner.isRunning ? "Apple on-device" : "—")))
                    .font(.caption).foregroundStyle(captioner.usingDeepgram ? .green : .secondary)

                if let err = captioner.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
                if !captioner.transcript.isEmpty {
                    Text(captioner.transcript)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if captioner.isRunning {
                    Text("Listening… speak now. Try two voices to see speaker labels.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        // Keep the button label in sync if captions self-terminate (errors / engine drop).
        .onChange(of: captioner.isRunning) { _, running in
            if !running { capsRunning = false }
        }
    }

    // MARK: Observability (Sentry)

    private var sentryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Observability (Sentry)")
                statusRow("Sentry", Telemetry.isEnabled ? "Enabled" : "Add package + DSN", ok: Telemetry.isEnabled)
                Button("Send test event to Sentry") {
                    Telemetry.breadcrumb("manual test from Test screen", category: "test")
                    Telemetry.captureMessage("glasse test event ✅", level: .info)
                    sentryResult = "Sent a test event — check Sentry → Issues (~1 min)."
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!Telemetry.isEnabled)
                Button("Send test error to Sentry") {
                    Telemetry.capture(VisionError.timedOut, ["source": "test screen"])
                    sentryResult = "Sent a handled error — check Sentry → Issues."
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!Telemetry.isEnabled)
                Text(Telemetry.isEnabled
                     ? sentryResult
                     : "Add the Sentry package in Xcode and paste your DSN in Secrets.swift to enable.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Bits

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
    private func statusRow(_ k: String, _ v: String, ok: Bool) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).foregroundStyle(ok ? .green : .orange)
        }
        .font(.subheadline)
    }
}
