//
//  SignVocabReader.swift
//  glasse
//
//  The camera + segmentation layer for the experimental whole-word sign recognizer
//  (signer → captions). Runs Apple Vision's on-device hand-pose model on glasses
//  frames OFF the main actor, turns each frame into a feature vector
//  (SignMotionMatcher.featureVector), accumulates a motion segment while a hand is
//  present, and on segment end either SAVES it as a template (teach mode) or
//  MATCHES it against the stored templates (read mode) via DTW.
//
//  Privacy: only hand-pose landmarks are computed; no frames leave the device.
//  Honesty: single-signer, small-vocab, deliberate-signing template matching — a
//  best-effort experiment, never claimed as reliable transcription.
//

import Foundation
import Vision
import UIKit
import CoreGraphics
import Observation

@Observable
@MainActor
final class SignVocabReader {
    enum Mode: Equatable { case reading, teaching(String) }

    var transcript = ""                       // assembled recognized words (read mode)
    var currentWord = ""                       // last recognized word
    var currentLevel: ConfidenceLevel = .low
    var handPresent = false
    var capturing = false                      // a motion segment is being collected
    var isRunning = false
    var lastTaught: String?                    // word just recorded (teach mode)
    var statusNote = ""
    var errorMessage: String?

    @ObservationIgnored private(set) var mode: Mode = .reading
    @ObservationIgnored private var buffer: [MotionFrame] = []
    @ObservationIgnored private var emptyRun = 0
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored let store: SignTemplateStore

    // Tuning (needs real-world calibration on device).
    private let maxDistance = 6.0     // DTW distance cutoff for a confident match
    private let minFrames = 5         // ignore too-short blips
    private let endGapFrames = 6      // ~0.4s of "no hand" ends a sign
    private let maxBuffer = 90        // cap a runaway segment (~6s)

    init(store: SignTemplateStore) { self.store = store }

    // MARK: Lifecycle

    func startReading() { mode = .reading; begin() }
    func startTeaching(_ word: String) { mode = .teaching(word); lastTaught = nil; begin() }

    private func begin() {
        generation &+= 1
        buffer = []; emptyRun = 0; capturing = false
        currentWord = ""; currentLevel = .low; handPresent = false
        statusNote = ""; errorMessage = nil
        isRunning = true
    }

    func stop() {
        isRunning = false
        generation &+= 1
        buffer = []; emptyRun = 0; capturing = false; handPresent = false
    }

    func clearTranscript() { transcript = ""; currentWord = ""; currentLevel = .low }

    // MARK: Frame processing

    /// Process one glasses frame. Cheap to call in a tight loop — drops frames while
    /// a detection is already running.
    func process(_ image: UIImage) async {
        guard !busy, isRunning, let cg = image.cgImage else { return }
        busy = true
        defer { busy = false }
        let gen = generation
        let points = await Task.detached(priority: .userInitiated) { SignVocabReader.detect(cg) }.value
        guard isRunning, gen == generation else { return }   // dropped if stopped/reset mid-flight
        ingest(points)
    }

    private func ingest(_ points: [HandJoint: CGPoint]?) {
        if let points, let f = SignMotionMatcher.featureVector(points: points) {
            handPresent = true; emptyRun = 0; capturing = true
            buffer.append(MotionFrame(features: f))
            if buffer.count > maxBuffer { buffer.removeFirst(buffer.count - maxBuffer) }
        } else {
            handPresent = false
            if capturing {
                emptyRun += 1
                if emptyRun >= endGapFrames { endSegment() }
            }
        }
    }

    private func endSegment() {
        let segment = buffer
        buffer = []; emptyRun = 0; capturing = false
        guard segment.count >= minFrames else { statusNote = "Too short — try again."; return }

        switch mode {
        case .teaching(let word):
            let template = SignTemplate(label: word, frames: SignMotionMatcher.resample(segment, to: 16))
            store.save(template)
            lastTaught = word
            statusNote = "Saved “\(word)”."
        case .reading:
            if let match = SignMotionMatcher.classify(segment, templates: store.templates, maxDistance: maxDistance) {
                currentWord = match.label
                currentLevel = match.confidence >= 0.66 ? .high : (match.confidence >= 0.4 ? .medium : .low)
                if currentLevel != .low { appendWord(match.label) }
            } else {
                currentWord = ""; currentLevel = .low
                statusNote = "No match — sign one of the taught words, clearly."
            }
        }
    }

    private func appendWord(_ word: String) {
        let pretty = word.capitalized
        transcript = transcript.isEmpty ? pretty : transcript + " " + pretty
    }

    // MARK: Vision (off the main actor) — same joint map as SignReader

    private static let jointMap: [(VNHumanHandPoseObservation.JointName, HandJoint)] = [
        (.wrist, .wrist),
        (.thumbCMC, .thumbCMC), (.thumbMP, .thumbMP), (.thumbIP, .thumbIP), (.thumbTip, .thumbTip),
        (.indexMCP, .indexMCP), (.indexPIP, .indexPIP), (.indexDIP, .indexDIP), (.indexTip, .indexTip),
        (.middleMCP, .middleMCP), (.middlePIP, .middlePIP), (.middleDIP, .middleDIP), (.middleTip, .middleTip),
        (.ringMCP, .ringMCP), (.ringPIP, .ringPIP), (.ringDIP, .ringDIP), (.ringTip, .ringTip),
        (.littleMCP, .littleMCP), (.littlePIP, .littlePIP), (.littleDIP, .littleDIP), (.littleTip, .littleTip),
    ]

    nonisolated private static func detect(_ cg: CGImage) -> [HandJoint: CGPoint]? {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first,
              let points = try? obs.recognizedPoints(.all) else { return nil }
        var dict: [HandJoint: CGPoint] = [:]
        for (vn, hj) in jointMap {
            if let p = points[vn], p.confidence > 0.3 { dict[hj] = p.location }
        }
        guard dict[.wrist] != nil, dict[.middleMCP] != nil, dict.count >= 12 else { return nil }
        return dict
    }
}
