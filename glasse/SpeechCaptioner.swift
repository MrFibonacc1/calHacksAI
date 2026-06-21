//
//  SpeechCaptioner.swift
//  glasse
//
//  Live speech-to-text for deaf / hard-of-hearing users: captures the
//  microphone and streams a running transcript using Apple's on-device Speech
//  framework. The transcript is shown large on screen and can be routed to the
//  in-lens display.
//
//  The recognizer is rotated on each final result so captioning continues
//  indefinitely instead of ending after the first utterance; recognition errors
//  back off and surface a visible message; and all audio-session changes go
//  through AudioCoordinator (released unconditionally on stop) so TTS can't be
//  left muted and the mic can't be left owned.
//

import Foundation
import Speech
import AVFoundation
import Observation

@Observable
@MainActor
final class SpeechCaptioner {
    var transcript: String = ""
    var isRunning: Bool = false
    var errorMessage: String?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer()
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let transcriber = DeepgramTranscriber()   // Deepgram streaming (diarized)
    private(set) var usingDeepgram = false   // observable: which STT engine is live
    // The tap runs on the real-time audio thread; guard the request handoff with
    // a lock so the audio thread never races the main actor reassigning it.
    @ObservationIgnored private let requestLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var _activeRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var committed = ""   // finalized text carried across request rotations
    @ObservationIgnored private var generation = 0   // ignores callbacks from rotated-out tasks
    @ObservationIgnored private var failureCount = 0
    @ObservationIgnored private var onUpdate: ((String, Bool) -> Void)?   // (transcript, isFinal)

    private let maxRetries = 5

    /// `onUpdate` receives the running transcript and whether this segment is
    /// finalized — callers that act on the words (e.g. caption commands) should
    /// wait for `isFinal` so they don't act on a half-spoken phrase.
    func start(onUpdate: @escaping (String, Bool) -> Void) async {
        guard !isRunning else { return }
        self.onUpdate = onUpdate
        errorMessage = nil
        // Release the mic if a phone call interrupts, instead of dying silently / fighting the call.
        AudioCoordinator.shared.onInterruptionBegan = { [weak self] in self?.handleAudioInterruption() }

        let micGranted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        guard micGranted else {
            errorMessage = "Microphone access is off. Enable it in Settings."
            return
        }

        // Prefer Deepgram streaming (Nova-3 + speaker diarization) when a key is set.
        if Deepgram.hasKey {
            AudioCoordinator.shared.beginRecording()
            transcript = ""
            let ok = transcriber.start(diarize: true) { [weak self] text, isFinal in
                guard let self else { return }
                self.transcript = text
                self.onUpdate?(text, isFinal)
            }
            if ok { usingDeepgram = true; isRunning = true; Telemetry.setTag("stt.engine", "deepgram"); return }
            AudioCoordinator.shared.endRecording()   // couldn't start; fall back to Apple
            Telemetry.captureMessage("Deepgram STT failed to start — using Apple", level: .warning)
        }

        // Fallback: Apple on-device speech recognition.
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
            stop()   // releases the mic/session even though isRunning never flipped
            return
        }

        transcript = ""
        committed = ""
        failureCount = 0
        isRunning = true
        Telemetry.setTag("stt.engine", "apple")
        startRecognition()
    }

    /// Creates a fresh recognition request + task, keeping the audio engine and
    /// its tap running, so captions never stop on their own.
    private func startRecognition() {
        guard isRunning, let recognizer else { return }
        task?.cancel()
        takeActiveRequest()?.endAudio()
        generation += 1
        let gen = generation

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = SpeechVocabulary.terms   // bias toward our vocabulary
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        setActiveRequest(request)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.isRunning, gen == self.generation else { return }
                if let result {
                    self.failureCount = 0
                    let text = result.bestTranscription.formattedString
                    self.transcript = self.committed.isEmpty ? text : self.committed + " " + text
                    self.onUpdate?(self.transcript, result.isFinal)
                    if result.isFinal {
                        self.committed = String(self.transcript.suffix(1000))   // bounded
                        self.startRecognition()
                    }
                } else if error != nil {
                    self.handleRecognitionError()
                }
            }
        }
    }

    /// A recognition error: rotate with a short backoff up to a cap, then give up
    /// with a visible message rather than spinning or freezing on stale text.
    private func handleRecognitionError() {
        guard isRunning, audioEngine.isRunning else {
            errorMessage = "Captions stopped unexpectedly. Tap Start live captions to resume."
            stop()
            return
        }
        failureCount += 1
        guard failureCount <= maxRetries else {
            errorMessage = "Captions stopped after repeated errors. Tap to resume."
            stop()
            return
        }
        let gen = generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard self.isRunning, gen == self.generation, self.audioEngine.isRunning else { return }
            self.startRecognition()
        }
    }

    /// A phone call (or other interruption) took the audio session — release the mic
    /// cleanly and tell the user, instead of fighting the call or freezing on stale text.
    private func handleAudioInterruption() {
        guard isRunning else { return }
        errorMessage = "Paused for a phone call. Tap Start live captions to resume."
        stop()
    }

    func stop() {
        // Release the shared session FIRST and unconditionally, so a failed start
        // (isRunning never set) can't leave TTS muted or the mic owned forever.
        AudioCoordinator.shared.endRecording()
        AudioCoordinator.shared.onInterruptionBegan = nil
        if usingDeepgram {
            transcriber.stop()
            usingDeepgram = false
            isRunning = false
            return
        }
        generation += 1   // ignore any in-flight callbacks
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        takeActiveRequest()?.endAudio()
        task?.cancel()
        task = nil
        isRunning = false
    }

    // MARK: - Thread-safe request handoff (tap runs on the audio thread)

    nonisolated private func appendToActiveRequest(_ buffer: AVAudioPCMBuffer) {
        requestLock.lock()
        let request = _activeRequest
        requestLock.unlock()
        request?.append(buffer)
    }

    nonisolated private func setActiveRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        requestLock.lock()
        _activeRequest = request
        requestLock.unlock()
    }

    @discardableResult
    nonisolated private func takeActiveRequest() -> SFSpeechAudioBufferRecognitionRequest? {
        requestLock.lock()
        let request = _activeRequest
        _activeRequest = nil
        requestLock.unlock()
        return request
    }
}
