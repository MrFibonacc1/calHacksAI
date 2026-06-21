//
//  VoiceCommander.swift
//  glasse
//
//  Captures a single spoken command (push-to-talk), ending automatically on a
//  short silence, a final result, or a hard timeout. Routes the mic through
//  AudioCoordinator so it never collides with TTS, and hands the request to the
//  audio thread via a lock (no main-actor access from the real-time tap).
//

import Foundation
import Speech
import AVFoundation
import Observation

@Observable
@MainActor
final class VoiceCommander {
    var isListening = false
    var heard = ""
    var status = ""

    @ObservationIgnored private let recognizer = SFSpeechRecognizer()
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var continuation: CheckedContinuation<String?, Never>?
    @ObservationIgnored private var finished = false

    /// Listens for one command and returns the transcript (nil if nothing/denied).
    func listenOnce(maxSeconds: TimeInterval = 8, silence: TimeInterval = 1.4) async -> String? {
        guard !isListening else { return nil }

        let speechAuth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speechAuth == .authorized else { status = "Speech permission is off. Enable it in Settings."; return nil }

        let mic = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        guard mic else { status = "Microphone access is off. Enable it in Settings."; return nil }

        guard let recognizer, recognizer.isAvailable else { status = "Voice isn't available right now."; return nil }

        finished = false
        heard = ""
        AudioCoordinator.shared.beginRecording()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.contextualStrings = SpeechVocabulary.terms   // bias toward our vocabulary
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        setRequest(req)

        do {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.appendBuffer(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            status = "Couldn't start listening."
            teardown()
            return nil
        }

        isListening = true
        status = "Listening…"
        resetSilenceTimer(silence)

        let hardStop = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(maxSeconds * 1_000_000_000))
            self.finish(self.heard.isEmpty ? nil : self.heard)
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                if let result {
                    self.heard = result.bestTranscription.formattedString
                    self.resetSilenceTimer(silence)
                    if result.isFinal { self.finish(self.heard) }
                } else if error != nil {
                    self.finish(self.heard.isEmpty ? nil : self.heard)
                }
            }
        }

        let text = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            self.continuation = c
        }
        hardStop.cancel()
        return text
    }

    func cancel() { finish(nil) }

    private func resetSilenceTimer(_ silence: TimeInterval) {
        silenceTask?.cancel()
        silenceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(silence * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.finish(self.heard.isEmpty ? nil : self.heard)
        }
    }

    private func finish(_ text: String?) {
        guard !finished else { return }
        finished = true
        teardown()
        let cont = continuation
        continuation = nil
        cont?.resume(returning: text)
    }

    private func teardown() {
        silenceTask?.cancel(); silenceTask = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        takeRequest()?.endAudio()
        task?.cancel(); task = nil
        isListening = false
        AudioCoordinator.shared.endRecording()
    }

    // MARK: - Thread-safe request handoff (tap runs on the audio thread)

    nonisolated private func appendBuffer(_ buffer: AVAudioPCMBuffer) {
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
