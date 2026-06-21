//
//  SignWriter.swift
//  glasse
//
//  The speech + state layer for the experimental "Sign what I say" coach — the
//  inverse of SignReader. It captures the wearer's own speech with Apple's
//  on-device recognizer, tokenizes the running transcript into fingerspelling
//  steps via the pure FingerspellGuide, and tracks a cursor the UI walks through
//  one handshape at a time. The lens / screen then shows the wearer how to spell
//  what they just said so they can sign it to a Deaf person.
//
//  On-device only: the wearer's clear speech doesn't need Deepgram, and keeping
//  recognition local matches the privacy posture (no audio leaves the phone).
//  Audio-session ownership goes through AudioCoordinator (released
//  unconditionally on stop) so TTS can't be left muted or the mic left owned —
//  the same hardening as SpeechCaptioner.
//
//  Honesty: teaches the static fingerspelling alphabet, not fluent ASL. Framed as
//  a best-effort coach in the UI.
//

import Foundation
import Speech
import AVFoundation
import Observation

@Observable
@MainActor
final class SignWriter {
    var heardText = ""                 // running transcript of what the wearer said
    var index = 0                      // cursor into `steps`
    var isListening = false
    var errorMessage: String?
    var stepIntervalMS: Int = 1300     // playback dwell per handshape (UI-adjustable)

    /// The steps for everything heard so far (pure, recomputed): whole-word ASL
    /// signs for words we have a clip for, fingerspelling for the rest.
    var steps: [FingerspellStep] { FingerspellGuide.steps(for: heardText, signs: SignAssets.signWords) }
    var current: FingerspellStep? { steps.indices.contains(index) ? steps[index] : nil }
    var canAdvance: Bool { index < steps.count - 1 }
    var hasSteps: Bool { !steps.isEmpty }

    // MARK: Cursor (driven by the view's playback pump, like SignView's frame pump)

    func advance() { if canAdvance { index += 1 } }
    func back()    { if index > 0 { index -= 1 } }
    func restart() { index = 0 }

    func reset() {
        generation += 1
        heardText = ""; committed = ""; index = 0; errorMessage = nil; failureCount = 0
    }

    // MARK: On-device speech capture (mirrors SpeechCaptioner's Apple path)

    @ObservationIgnored private let recognizer = SFSpeechRecognizer()
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let requestLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var _activeRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var committed = ""    // finalized text across request rotations
    @ObservationIgnored private var generation = 0    // ignores callbacks from rotated-out tasks
    @ObservationIgnored private var failureCount = 0
    private let maxRetries = 5

    func start() async {
        guard !isListening else { return }
        errorMessage = nil

        let micGranted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        guard micGranted else {
            errorMessage = "Microphone access is off. Enable it in Settings."
            return
        }
        let speechAuth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speechAuth == .authorized else {
            errorMessage = "Speech recognition isn't allowed. Enable it in Settings."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available right now."
            return
        }

        AudioCoordinator.shared.beginRecording()
        do {
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.appendToActiveRequest(buffer)   // thread-safe; no main-actor access
            }
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            errorMessage = "Couldn't start listening: \(error.localizedDescription)"
            stop()
            return
        }

        heardText = ""; committed = ""; index = 0; failureCount = 0
        isListening = true
        startRecognition()
    }

    /// Fresh request + task, keeping the engine + tap running, so the wearer can
    /// speak indefinitely (Apple's per-request ~1-min cap would otherwise stop it).
    private func startRecognition() {
        guard isListening, let recognizer else { return }
        task?.cancel()
        takeActiveRequest()?.endAudio()
        generation += 1
        let gen = generation

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        setActiveRequest(request)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.isListening, gen == self.generation else { return }
                if let result {
                    self.failureCount = 0
                    let text = result.bestTranscription.formattedString
                    self.heardText = self.committed.isEmpty ? text : self.committed + " " + text
                    if result.isFinal {
                        self.committed = String(self.heardText.suffix(1000))   // bounded
                        self.startRecognition()
                    }
                } else if error != nil {
                    self.handleRecognitionError()
                }
            }
        }
    }

    private func handleRecognitionError() {
        guard isListening, audioEngine.isRunning else {
            errorMessage = "Listening stopped unexpectedly. Tap Start to resume."
            stop()
            return
        }
        failureCount += 1
        guard failureCount <= maxRetries else {
            errorMessage = "Listening stopped after repeated errors. Tap to resume."
            stop()
            return
        }
        let gen = generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard self.isListening, gen == self.generation, self.audioEngine.isRunning else { return }
            self.startRecognition()
        }
    }

    func stop() {
        // Release the shared session FIRST and unconditionally, so a failed start
        // can't leave TTS muted or the mic owned forever.
        AudioCoordinator.shared.endRecording()
        generation += 1
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        takeActiveRequest()?.endAudio()
        task?.cancel()
        task = nil
        isListening = false
    }

    // MARK: Thread-safe request handoff (tap runs on the audio thread)

    nonisolated private func appendToActiveRequest(_ buffer: AVAudioPCMBuffer) {
        requestLock.lock(); let request = _activeRequest; requestLock.unlock()
        request?.append(buffer)
    }
    nonisolated private func setActiveRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        requestLock.lock(); _activeRequest = request; requestLock.unlock()
    }
    @discardableResult
    nonisolated private func takeActiveRequest() -> SFSpeechAudioBufferRecognitionRequest? {
        requestLock.lock(); let request = _activeRequest; _activeRequest = nil; requestLock.unlock()
        return request
    }
}
