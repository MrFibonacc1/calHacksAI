//
//  SignReader.swift
//  glasse
//
//  The camera + temporal layer for the experimental fingerspelling reader.
//  Runs Apple Vision's on-device hand-pose model (VNDetectHumanHandPoseRequest)
//  on glasses frames OFF the main actor, maps the 21 joints into a HandSample,
//  classifies a letter via the pure SignClassifier, then debounces over several
//  frames before committing a letter and assembles letters into words.
//
//  Privacy: only hand-pose landmarks are computed; no frames leave the device.
//  Honesty: reads deliberate, static fingerspelling for a distinct letter subset
//  — it is a best-effort reader, not an ASL interpreter.
//

import Foundation
import Vision
import UIKit
import Observation

@Observable
@MainActor
final class SignReader {
    var transcript = ""                      // assembled words
    var currentLetter = ""                   // live best-guess (may be low confidence)
    var currentLevel: ConfidenceLevel = .low
    var handPresent = false
    var isRunning = false
    var errorMessage: String?

    @ObservationIgnored private var busy = false        // drop frames while one is in flight
    @ObservationIgnored private var generation = 0      // invalidates in-flight detections on stop/reset
    @ObservationIgnored private var assembler = SignAssembler()   // pure, unit-tested temporal layer

    func reset() {
        generation &+= 1
        assembler.reset()
        transcript = ""; currentLetter = ""; currentLevel = .low; handPresent = false
        errorMessage = nil
    }

    /// Process one glasses frame. Cheap to call in a tight loop — it drops frames
    /// while a detection is already running.
    func process(_ image: UIImage) async {
        guard !busy, isRunning else { return }
        busy = true
        defer { busy = false }
        guard let cg = image.cgImage else { return }
        let gen = generation
        let result = await Task.detached(priority: .userInitiated) { SignReader.detect(cg) }.value
        // Drop the result if we were stopped or reset while detecting.
        guard isRunning, gen == generation else { return }
        ingest(result.reading, present: result.present)
    }

    // MARK: Temporal assembly (main actor) — delegates to the pure SignAssembler

    private func ingest(_ reading: SignReading, present: Bool) {
        assembler.feed(reading, present: present)
        handPresent = assembler.handPresent
        currentLetter = assembler.currentLetter
        currentLevel = assembler.currentLevel
        transcript = assembler.transcript
    }

    // MARK: Vision (off the main actor)

    private static let jointMap: [(VNHumanHandPoseObservation.JointName, HandJoint)] = [
        (.wrist, .wrist),
        (.thumbCMC, .thumbCMC), (.thumbMP, .thumbMP), (.thumbIP, .thumbIP), (.thumbTip, .thumbTip),
        (.indexMCP, .indexMCP), (.indexPIP, .indexPIP), (.indexDIP, .indexDIP), (.indexTip, .indexTip),
        (.middleMCP, .middleMCP), (.middlePIP, .middlePIP), (.middleDIP, .middleDIP), (.middleTip, .middleTip),
        (.ringMCP, .ringMCP), (.ringPIP, .ringPIP), (.ringDIP, .ringDIP), (.ringTip, .ringTip),
        (.littleMCP, .littleMCP), (.littlePIP, .littlePIP), (.littleDIP, .littleDIP), (.littleTip, .littleTip),
    ]

    nonisolated private static func detect(_ cg: CGImage) -> (reading: SignReading, present: Bool) {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return (.none, false) }

        guard let obs = request.results?.first,
              let points = try? obs.recognizedPoints(.all) else { return (.none, false) }

        var dict: [HandJoint: CGPoint] = [:]
        var confSum = 0.0, confN = 0
        for (vn, hj) in jointMap {
            if let p = points[vn], p.confidence > 0.3 {
                dict[hj] = p.location
                confSum += Double(p.confidence); confN += 1
            }
        }
        guard dict[.wrist] != nil, dict[.middleMCP] != nil, dict.count >= 12 else {
            return (.none, false)
        }
        let sample = HandSample(points: dict, jointConfidence: confN > 0 ? confSum / Double(confN) : 0.5)
        return (SignClassifier.classify(sample), true)
    }
}

extension HandSample: @unchecked Sendable {}   // only constructed + consumed inside detect()
