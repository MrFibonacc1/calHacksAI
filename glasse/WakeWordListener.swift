//
//  WakeWordListener.swift
//  glasse
//
//  Always-on (when idle) on-device listener for the "glasses" wake phrase.
//  Used in the NON-captions path: when captions are running we scan that
//  transcript instead (no second microphone). Mirrors SpeechCaptioner's
//  recognizer rotation (so it never stops after one minute) and VoiceCommander's
//  lock-guarded request handoff (the tap runs on the real-time audio thread).
//
//  On-device only (`requiresOnDeviceRecognition`) — no audio leaves the phone.
//  It takes the mic via AudioCoordinator, so the app's TTS is suppressed while
//  it listens; the controller in ContentView only runs it while the app is idle
//  (not speaking, capturing, working, or captioning) and stops it the moment any
//  of those begins.
//

import Foundation
import Speech
import AVFoundation
import Observation

@Observable
@MainActor
final class WakeWordListener {
    private(set) var isRunning = false
    var lastError: String?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer()
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var failureCount = 0
    @ObservationIgnored private var onWake: ((String) -> Void)?

    private let maxRetries = 8

    /// Begin listening. Assumes mic + speech permission are already granted (the
    /// app requests them for captions / voice control); fails quietly via
    /// `lastError` otherwise. `onWake` receives the command spoken after the wake
    /// phrase (possibly empty when the user only said "glasses").
    func start(onWake: @escaping (String) -> Void) {
        guard !isRunning else { return }
        // Never take the mic another component already owns or that TTS is using —
        // defense-in-depth behind ContentView's wakeListenerShouldRun gate.
        guard !AudioCoordinator.shared.isRecording, !AudioCoordinator.shared.isPlaying else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            lastError = "Speech permission is off — enable it in Settings."
            return
        }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            lastError = "On-device wake word isn't available on this device."
            return
        }
        self.onWake = onWake
        lastError = nil
        failureCount = 0
        AudioCoordinator.shared.beginRecording()
        do {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.append(buffer)   // thread-safe; no main-actor access
            }
            engine.prepare()
            try engine.start()
        } catch {
            // We took the session above but never went live, so release it here
            // explicitly (stop() is a no-op until isRunning, by design below).
            lastError = "Couldn't start the wake-word microphone."
            engine.inputNode.removeTap(onBus: 0)
            AudioCoordinator.shared.endRecording()
            return
        }
        isRunning = true
        listen()
    }

    func stop() {
        // No-op unless WE actually own the mic. CRITICAL: the onWillSpeak hook
        // calls stop() before every TTS, so an unconditional endRecording() here
        // would release a session owned by the captioner or VoiceCommander and
        // let TTS talk over live captions.
        guard isRunning else { return }
        generation += 1   // ignore any in-flight callbacks
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        takeRequest()?.endAudio()
        task?.cancel(); task = nil
        isRunning = false
        AudioCoordinator.shared.endRecording()
    }

    /// One recognition request; rotates on final so listening continues forever.
    private func listen() {
        guard isRunning, let recognizer else { return }
        task?.cancel()
        takeRequest()?.endAudio()
        generation += 1
        let gen = generation

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.contextualStrings = SpeechVocabulary.terms   // bias toward the wake word + commands
        req.requiresOnDeviceRecognition = true
        setRequest(req)

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.isRunning, gen == self.generation else { return }
                if let result {
                    self.failureCount = 0
                    // Only act on a FINALIZED utterance, so the command after the
                    // wake phrase is complete ("glasses turn on captions") and
                    // not a truncated partial ("glasses turn").
                    if result.isFinal {
                        if let command = WakeWord.match(result.bestTranscription.formattedString) {
                            let cb = self.onWake
                            self.stop()
                            cb?(command)
                            return
                        }
                        self.listen()   // no wake → rotate, keep listening
                    }
                } else if let error {
                    self.handleError(error)
                }
            }
        }
    }

    /// Errors are normal for an always-on listener: on-device recognition ends a
    /// request with a "no speech" error (kAFAssistantErrorDomain) during the
    /// silence between wake words. Those are benign — rotate without counting them
    /// so a quiet room never exhausts the retry budget. Only genuinely repeated
    /// failures (engine breaking, recognizer lost) trip the cap.
    private func handleError(_ error: Error) {
        guard isRunning else { return }
        let benign = (error as NSError).domain == "kAFAssistantErrorDomain"
        if benign {
            // Normal "no speech" during silence — but if the recognizer itself has
            // gone unavailable, stop rather than busy-rotating requests forever.
            guard recognizer?.isAvailable == true else {
                lastError = "Speech recognition is unavailable."
                stop()
                return
            }
        } else {
            failureCount += 1
            guard failureCount <= maxRetries else {
                lastError = "Wake word stopped after repeated errors."
                stop()
                return
            }
        }
        let gen = generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: benign ? 250_000_000 : 400_000_000)
            guard self.isRunning, gen == self.generation else { return }
            self.listen()
        }
    }

    // MARK: - thread-safe request handoff (tap runs on the audio thread)

    nonisolated private func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let r = request; lock.unlock()
        r?.append(buffer)
    }
    nonisolated private func setRequest(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); request = r; lock.unlock()
    }
    @discardableResult
    nonisolated private func takeRequest() -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock(); let r = request; request = nil; lock.unlock(); return r
    }
}
