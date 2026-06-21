//
//  AudioCoordinator.swift
//  glasse
//
//  Single owner of the shared AVAudioSession. Speech-to-text (live captions)
//  and text-to-speech both need the session, but with conflicting categories
//  (.record vs .playback). Without coordination they clobber each other and
//  silently kill the caption mic. Everything routes through here instead:
//  while a recording session is live, playback requests are ignored so the mic
//  keeps working.
//

import AVFoundation

@MainActor
final class AudioCoordinator {
    static let shared = AudioCoordinator()
    private init() {
        // Yield cleanly to phone calls: otherwise the session keeps/re-grabs the single
        // Bluetooth HFP route and fights CallKit (choppy/dropped call audio), while
        // captions die silently. Observe interruptions and let the captioner release the
        // mic on .began.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            Task { @MainActor in self?.handleInterruption(typeRaw: raw) }
        }
    }

    /// True while live captions / a command own the microphone.
    private(set) var isRecording = false

    /// True while a phone call (or other audio interruption) owns the session. While
    /// interrupted we refuse to (re)activate recording or playback, so we don't fight
    /// the call over the single Bluetooth HFP route.
    private(set) var interrupted = false

    /// Fired when an interruption (e.g. an incoming call) begins, so the captioner can
    /// release the mic and surface "tap to resume" instead of dying silently.
    var onInterruptionBegan: (() -> Void)?

    private func handleInterruption(typeRaw: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            interrupted = true
            onInterruptionBegan?()
        case .ended:
            interrupted = false   // captioner showed "tap to resume"; the user restarts
        @unknown default:
            break
        }
    }

    /// True while TTS playback is (about to be) audible. Lets the wake-word
    /// listener refuse to grab the mic mid-clip, so exclusion is bidirectional:
    /// `beginPlayback` already yields to recording, and now a recording start can
    /// check `isPlaying` before stealing the session out from under TTS.
    private(set) var isPlaying = false

    /// Configure the session for spoken playback (TTS → glasses speaker over
    /// A2DP). No-op while a recording session owns the mic.
    func beginPlayback() {
        guard !isRecording, !interrupted else { return }
        isPlaying = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio,
                                 options: [.duckOthers, .allowBluetoothA2DP])
        try? session.setActive(true)
    }

    /// Mark playback finished (called by the speaker when TTS stops).
    func endPlayback() { isPlaying = false }

    /// Take the mic for speech recognition. Uses the PHONE's built-in mic — NOT the
    /// glasses' Bluetooth mic. The only Bluetooth profile that carries a mic is HFP,
    /// which is the phone-CALL audio channel; forcing it flipped the glasses into a
    /// phantom "call" every time the app listened. (Tradeoff: you speak toward the
    /// phone for commands/captions; Bob's audio still plays to the glasses over A2DP.)
    func beginRecording() {
        guard !interrupted else { return }   // don't grab the mic during a call
        isRecording = true
        isPlaying = false   // recording supersedes playback
        let session = AVAudioSession.sharedInstance()
        // NO .allowBluetooth → no HFP route → no "call mode" on the glasses.
        try? session.setCategory(.record, mode: .default, options: [.duckOthers])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// Release the mic.
    func endRecording() {
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
