//
//  Deepgram.swift
//  glasse
//
//  Deepgram voice AI: text-to-speech (Aura) and streaming speech-to-text
//  (Nova-3, with speaker diarization). Both degrade gracefully — if there's no
//  Deepgram key, no network, or an error, the callers fall back to Apple's
//  on-device speech, so the app always works.
//

import Foundation
import AVFoundation

enum Deepgram {
    static var hasKey: Bool {
        Secrets.deepgramAPIKey != "PASTE_YOUR_DEEPGRAM_KEY_HERE" && !Secrets.deepgramAPIKey.isEmpty
    }
    static var authHeader: String { "Token \(Secrets.deepgramAPIKey)" }
}

// MARK: - Text Intelligence (Read API) — sentiment for the caption tone pill

/// Deepgram's Read API runs sentiment on TEXT (it isn't available on the live STT
/// socket), so we call it on each finalized caption line to refine the on-device
/// tone hint with a cloud sentiment read. Degrades gracefully: nil → caller keeps
/// the instant on-device (Apple NaturalLanguage) tone.
enum DeepgramRead {
    /// Average sentiment LABEL ("positive" / "neutral" / "negative") for `text`,
    /// or nil if there's no key, the request fails, or the response lacks one.
    static func sentiment(for text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Deepgram.hasKey, !trimmed.isEmpty else { return nil }
        var comps = URLComponents(string: "https://api.deepgram.com/v1/read")!
        comps.queryItems = [
            URLQueryItem(name: "sentiment", value: "true"),
            URLQueryItem(name: "language", value: "en"),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(Deepgram.authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": trimmed])
        req.timeoutInterval = 4   // fail fast to on-device sentiment

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [String: Any],
              let sentiments = results["sentiments"] as? [String: Any],
              let average = sentiments["average"] as? [String: Any],
              let label = average["sentiment"] as? String else { return nil }
        return label
    }
}

// MARK: - Text-to-Speech (Aura)

@MainActor
final class DeepgramTTS {
    /// Aura-2 voice. Swap for another Deepgram voice id if you prefer.
    var model = "aura-2-thalia-en"
    /// Human-readable outcome of the last `speak` — for honest diagnostics
    /// (distinguishes a bad key / network / HTTP error from a local playback failure).
    private(set) var lastStatus = ""
    private var player: AVAudioPlayer?

    /// Duration (seconds) of the most recent prepared playback — lets callers
    /// (e.g. the wake-word coordination) know how long TTS will last. Nil before
    /// the first successful `speak`.
    var lastPlaybackDuration: Double? { player?.duration }

    /// Whether Aura audio is currently playing — lets the speaker defer flipping
    /// `isSpeaking` off while a clip is still audible.
    var isPlaying: Bool { player?.isPlaying ?? false }

    /// Synthesize `text` and play it. Returns true if it spoke; false to fall
    /// back to Apple TTS.
    func speak(_ text: String) async -> Bool {
        guard Deepgram.hasKey, !text.isEmpty else { lastStatus = "no key set"; return false }
        var comps = URLComponents(string: "https://api.deepgram.com/v1/speak")!
        comps.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "encoding", value: "mp3"),
        ]
        guard let url = comps.url else { lastStatus = "bad url"; return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(Deepgram.authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        req.timeoutInterval = 6   // fail fast to Apple TTS so a bad network doesn't block the wake listener

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            // Timeout or no connection — NOT a key problem.
            lastStatus = (error as? URLError)?.code == .timedOut ? "request timed out (slow network)" : "network error / offline"
            return false
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { lastStatus = "HTTP \(code) (401 = bad key, 402 = no credit)"; return false }
        guard !data.isEmpty else { lastStatus = "empty audio response"; return false }
        do {
            let p = try AVAudioPlayer(data: data)
            player?.stop()
            player = p
            p.prepareToPlay()
            if p.play() { lastStatus = "playing (\(data.count) bytes)"; return true }
            // Audio arrived fine but the session wouldn't play it.
            lastStatus = "got \(data.count) bytes but playback failed — check the audio route / a live mic or caption session may hold the session"
            return false
        } catch {
            lastStatus = "audio decode failed"
            return false
        }
    }

    func stop() { player?.stop(); player = nil }
}

// MARK: - Streaming Speech-to-Text (Nova-3 + diarization)

@MainActor
final class DeepgramTranscriber {
    private(set) var isRunning = false

    private let engine = AVAudioEngine()
    private let wsLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var ws: URLSessionWebSocketTask?
    private var onUpdate: ((String, Bool) -> Void)?   // (transcript, isFinal)
    private var committed = ""   // finalized text
    private var diarize = true

    /// Opens the stream and starts sending mic audio. Returns false if it can't
    /// start (no key, no converter, engine error) so the caller can fall back.
    /// Caller must have already obtained microphone permission. `onUpdate` gets the
    /// running transcript and whether this segment is finalized.
    func start(diarize: Bool, onUpdate: @escaping (String, Bool) -> Void) -> Bool {
        guard Deepgram.hasKey, !isRunning else { return false }
        self.onUpdate = onUpdate
        self.diarize = diarize
        committed = ""

        var comps = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        comps.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "language", value: "en-US"),   // explicit English (also required for keyterm)
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "diarize", value: diarize ? "true" : "false"),
        ]
        // Keyterm prompting (Nova-3): bias toward the wake word + command vocabulary
        // so the app's distinctive terms ("fingerspelling", "braille", …) transcribe
        // more reliably. One `keyterm` per phrase.
        comps.queryItems? += SpeechVocabulary.terms.map { URLQueryItem(name: "keyterm", value: $0) }
        guard let url = comps.url else { return false }
        var req = URLRequest(url: url)
        req.setValue(Deepgram.authHeader, forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: req)
        setWS(task)
        task.resume()
        receive()

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            cancelWS(); return false
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.convertAndSend(buffer, converter: converter, outFormat: outFormat)
        }
        engine.prepare()
        do { try engine.start() } catch { stop(); return false }
        isRunning = true
        return true
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        // Tell Deepgram we're done, then close.
        if let s = takeWS() {
            let close = #"{"type":"CloseStream"}"#
            s.send(.string(close)) { _ in }
            s.cancel(with: .goingAway, reason: nil)
        }
        isRunning = false
    }

    // MARK: Audio → 16k linear16 → WebSocket (runs on the audio thread)

    nonisolated private func convertAndSend(_ buffer: AVAudioPCMBuffer,
                                            converter: AVAudioConverter,
                                            outFormat: AVAudioFormat) {
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard convError == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let data = Data(bytes: ch[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
        sendPCM(data)
    }

    nonisolated private func sendPCM(_ data: Data) {
        wsLock.lock(); let s = ws; wsLock.unlock()
        s?.send(.data(data)) { _ in }
    }
    nonisolated private func setWS(_ task: URLSessionWebSocketTask?) {
        wsLock.lock(); ws = task; wsLock.unlock()
    }
    nonisolated private func cancelWS() {
        wsLock.lock(); let s = ws; ws = nil; wsLock.unlock()
        s?.cancel(with: .goingAway, reason: nil)
    }
    nonisolated private func takeWS() -> URLSessionWebSocketTask? {
        wsLock.lock(); let s = ws; ws = nil; wsLock.unlock(); return s
    }

    // MARK: Receive transcripts

    private func receive() {
        wsLock.lock(); let s = ws; wsLock.unlock()
        s?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                if case .success(let message) = result {
                    if case .string(let text) = message { self.handle(text) }
                    self.receive()   // keep listening
                }
                // on failure we stop receiving; caller's transcript stays as-is
            }
        }
    }

    private func handle(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channel = obj["channel"] as? [String: Any],
              let alts = channel["alternatives"] as? [[String: Any]],
              let alt = alts.first else { return }
        let isFinal = (obj["is_final"] as? Bool) ?? false

        let line: String
        if diarize, let words = alt["words"] as? [[String: Any]], !words.isEmpty {
            line = Self.diarized(words)
        } else {
            line = (alt["transcript"] as? String) ?? ""
        }
        guard !line.isEmpty else { return }

        if isFinal {
            committed = committed.isEmpty ? line : committed + "\n" + line
            committed = String(committed.suffix(1200))
            onUpdate?(committed, true)
        } else {
            onUpdate?(committed.isEmpty ? line : committed + "\n" + line, false)
        }
    }

    /// Groups words by speaker into "Speaker 1: …" lines.
    private static func diarized(_ words: [[String: Any]]) -> String {
        var out: [String] = []
        var current = -1
        var buffer = ""
        for w in words {
            let spk = (w["speaker"] as? Int) ?? 0
            let token = (w["punctuated_word"] as? String) ?? (w["word"] as? String) ?? ""
            if spk != current {
                if !buffer.isEmpty { out.append("Speaker \(current + 1): \(buffer)") }
                current = spk
                buffer = token
            } else {
                buffer += " " + token
            }
        }
        if !buffer.isEmpty { out.append("Speaker \(current + 1): \(buffer)") }
        return out.joined(separator: "\n")
    }
}
