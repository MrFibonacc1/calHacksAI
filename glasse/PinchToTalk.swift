//
//  PinchToTalk.swift
//  glasse
//
//  Hands-free trigger via a camera-seen gesture: raise your hand into the glasses'
//  forward view and pinch index+thumb to start a voice command (like a push-to-
//  talk button you press in the air). Reuses the on-device Apple Vision hand-pose
//  model and the pinch geometry from SignClassifier; a deliberate, debounced pinch
//  (PinchGate) fires once and then re-arms only after the hand opens.
//
//  Unlike the wake word, this uses the CAMERA, not the microphone, so it never
//  competes with TTS or the caption mic — the command capture (mic) happens
//  afterwards via the normal conductor flow.
//
//  Privacy: only hand-pose landmarks are computed on-device; no frames leave the
//  phone. Cost/limits: needs the glasses camera streaming, and your hand must be
//  in the forward camera view (a pinch held at your side isn't visible).
//

import Foundation
import Vision
import UIKit
import Observation

@Observable
@MainActor
final class PinchToTalk {
    private(set) var isRunning = false
    private(set) var handPresent = false   // for on-screen feedback

    @ObservationIgnored private var busy = false       // drop frames while one is in flight
    @ObservationIgnored private var generation = 0     // invalidate in-flight detections on stop
    @ObservationIgnored private var gate = PinchGate()  // pure, unit-tested debounce
    @ObservationIgnored private var onPinch: (() -> Void)?

    /// Start watching; returns a token to pass to stop(). Deliberately does NOT
    /// reset the debounce gate — a pinch still held when the loop resumes (after a
    /// conductor turn) must not re-fire until the hand opens.
    @discardableResult
    func start(onPinch: @escaping () -> Void) -> Int {
        generation &+= 1
        self.onPinch = onPinch
        isRunning = true
        return generation
    }

    /// Stop — a no-op unless `token` is still current, so an old loop's teardown
    /// can't clobber a freshly-restarted one.
    func stop(_ token: Int) {
        guard token == generation else { return }
        generation &+= 1
        isRunning = false
        handPresent = false
        onPinch = nil
    }

    /// Process one glasses frame. Cheap to call in a tight loop — drops frames
    /// while a detection is already running. Fires `onPinch` once per deliberate
    /// pinch (held, then released).
    func process(_ image: UIImage) async {
        guard !busy, isRunning else { return }
        busy = true
        defer { busy = false }
        guard let cg = image.cgImage else { return }
        let gen = generation
        let result = await Task.detached(priority: .userInitiated) { PinchToTalk.detect(cg) }.value
        guard isRunning, gen == generation else { return }   // stopped/reset mid-detection
        handPresent = result.present
        if gate.feed(result.pinching) { onPinch?() }
    }

    // MARK: Vision (off the main actor) — only the 4 joints a pinch needs

    nonisolated private static func detect(_ cg: CGImage) -> (pinching: Bool, present: Bool) {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return (false, false) }

        guard let obs = request.results?.first,
              let points = try? obs.recognizedPoints(.all) else { return (false, false) }
        // A hand is present from here on (obs exists).

        // Pinch joints (wrist+middleMCP for scale, thumbTip+indexTip for the pinch)
        // plus the middle/ring/little joints so isPinchTrigger can require a CLOSED
        // hand — distinguishing a deliberate pinch from the F/open fingerspelling
        // shapes that share thumb–index contact.
        let needed: [(VNHumanHandPoseObservation.JointName, HandJoint)] = [
            (.wrist, .wrist), (.middleMCP, .middleMCP), (.thumbTip, .thumbTip), (.indexTip, .indexTip),
            (.middlePIP, .middlePIP), (.middleTip, .middleTip),
            (.ringMCP, .ringMCP), (.ringPIP, .ringPIP), (.ringTip, .ringTip),
            (.littleMCP, .littleMCP), (.littlePIP, .littlePIP), (.littleTip, .littleTip),
        ]
        var dict: [HandJoint: CGPoint] = [:]
        for (vn, hj) in needed {
            if let p = points[vn], p.confidence > 0.3 { dict[hj] = p.location }
        }
        // Need the 4 pinch joints; the curl joints are optional (a missing finger
        // reads as "not extended", i.e. curled).
        guard dict[.wrist] != nil, dict[.middleMCP] != nil,
              dict[.thumbTip] != nil, dict[.indexTip] != nil else { return (false, true) }
        return (SignClassifier.isPinchTrigger(HandSample(points: dict)), true)
    }
}
