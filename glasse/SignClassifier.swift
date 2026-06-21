//
//  SignClassifier.swift
//  glasse
//
//  Pure, dependency-free fingerspelling classifier: given 21 hand-pose joints
//  (as produced by Apple Vision's VNDetectHumanHandPoseRequest, an on-device ML
//  model), decide which static ASL fingerspelling letter the hand is forming.
//
//  This file imports ONLY Foundation + CoreGraphics (no Vision / UIKit), so the
//  classification logic can be compiled and unit-tested with `swiftc` off-device.
//  SignReader.swift maps Vision joints → HandJoint here and adds the camera /
//  temporal / UI layer.
//
//  Scope & honesty: this reads DELIBERATE, front-facing, static handshapes for a
//  distinct subset of the alphabet. Motion letters (J, Z) and shapes that need
//  orientation or thumb-tuck detail (G, H, M, N, P, Q, T, X …) are intentionally
//  reported at low confidence rather than guessed. It is a best-effort reader,
//  NOT an ASL interpreter.
//

import Foundation
import CoreGraphics

/// The 21 hand joints, matching Vision's VNHumanHandPoseObservation.JointName.
enum HandJoint: String, CaseIterable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

/// One frame's worth of detected joints (image-normalized points).
struct HandSample {
    var points: [HandJoint: CGPoint]
    /// Mean detection confidence of the joints (0...1); scales output confidence.
    var jointConfidence: Double = 1.0
    func p(_ j: HandJoint) -> CGPoint? { points[j] }
}

enum ConfidenceLevel: String { case low, medium, high }

struct SignReading: Equatable, Sendable {
    let letter: String       // "" when no confident letter
    let confidence: Double   // 0...1
    let isOpenHand: Bool     // flat / open palm → treated as a word boundary

    var level: ConfidenceLevel {
        confidence >= 0.72 ? .high : (confidence >= 0.5 ? .medium : .low)
    }
    static let none = SignReading(letter: "", confidence: 0, isOpenHand: false)
}

enum SignClassifier {

    // MARK: Geometry helpers

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// Interior angle (degrees) at vertex `b` of the path a-b-c. ~180 = straight.
    private static func angle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let v1 = CGPoint(x: a.x - b.x, y: a.y - b.y)
        let v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
        let m = hypot(v1.x, v1.y) * hypot(v2.x, v2.y)
        guard m > 0 else { return 180 }
        let cosv = max(-1, min(1, (v1.x * v2.x + v1.y * v2.y) / m))
        return acos(cosv) * 180 / .pi
    }

    /// A finger is extended if it's roughly straight at the PIP joint AND its tip
    /// reaches past the PIP away from the wrist. Orientation-independent.
    private static func fingerExtended(_ s: HandSample, _ mcp: HandJoint, _ pip: HandJoint,
                                       _ tip: HandJoint, wrist: CGPoint) -> Bool {
        guard let m = s.p(mcp), let p = s.p(pip), let t = s.p(tip) else { return false }
        let straight = angle(m, p, t) > 150
        let reaches = dist(t, wrist) > dist(p, wrist)
        return straight && reaches
    }

    // MARK: Classification

    /// Classify a single frame's handshape into a fingerspelling letter.
    static func classify(_ s: HandSample) -> SignReading {
        guard let wrist = s.p(.wrist), let midMCP = s.p(.middleMCP) else { return .none }
        let scale = max(dist(wrist, midMCP), 0.0001)   // palm length → normalizes thresholds
        let conf = max(0, min(1, s.jointConfidence))

        let index  = fingerExtended(s, .indexMCP, .indexPIP, .indexTip, wrist: wrist)
        let middle = fingerExtended(s, .middleMCP, .middlePIP, .middleTip, wrist: wrist)
        let ring   = fingerExtended(s, .ringMCP, .ringPIP, .ringTip, wrist: wrist)
        let little = fingerExtended(s, .littleMCP, .littlePIP, .littleTip, wrist: wrist)

        // Thumb "out": straightish and its tip held away from the index knuckle.
        let thumbStraight: Bool = {
            guard let c = s.p(.thumbCMC), let mp = s.p(.thumbMP), let t = s.p(.thumbTip) else { return false }
            return angle(c, mp, t) > 140
        }()
        let thumbAwayFromIndex: Bool = {
            guard let t = s.p(.thumbTip), let iMCP = s.p(.indexMCP) else { return false }
            return dist(t, iMCP) > 0.55 * scale
        }()
        let thumb = thumbStraight && thumbAwayFromIndex

        // Thumb–index pinch (F, and the basis of O): tips touching.
        let pinch: Bool = {
            guard let tt = s.p(.thumbTip), let it = s.p(.indexTip) else { return false }
            return dist(tt, it) < 0.45 * scale
        }()

        // All five fingertips clustered near each other (O).
        let tipsClustered: Bool = {
            let tips: [HandJoint] = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
            let pts = tips.compactMap { s.p($0) }
            guard pts.count == 5 else { return false }
            let cx = pts.map(\.x).reduce(0, +) / 5, cy = pts.map(\.y).reduce(0, +) / 5
            let center = CGPoint(x: cx, y: cy)
            return pts.allSatisfy { dist($0, center) < 0.45 * scale }
        }()

        // Index/middle spread (V) vs together (U).
        let indexMiddleSpread: Bool = {
            guard let i = s.p(.indexTip), let m = s.p(.middleTip) else { return false }
            return dist(i, m) > 0.55 * scale
        }()

        func r(_ letter: String, _ base: Double, openHand: Bool = false) -> SignReading {
            SignReading(letter: letter, confidence: base * conf, isOpenHand: openHand)
        }

        // Order matters: most specific / most reliable shapes first.

        // Open / flat hand → word boundary (and the ambiguous "5"/B-with-thumb).
        if index && middle && ring && little && thumb {
            return r("", 0.8, openHand: true)
        }

        // F: thumb+index pinch, other three extended.
        if pinch && middle && ring && little { return r("F", 0.78) }

        // O: all fingertips meet.
        if tipsClustered && !index && !middle { return r("O", 0.6) }

        switch (thumb, index, middle, ring, little) {
        case (false, true, true, true, true):  return r("B", 0.8)   // four up, thumb folded
        case (false, false, false, false, false),
             (true,  false, false, false, false):                    // fist (A / S / E / T family)
            return r("A", thumb ? 0.62 : 0.5)
        case (true,  true,  false, false, false): return r("L", 0.82)
        case (true,  false, false, false, true):  return r("Y", 0.82)
        case (false, false, false, false, true):  return r("I", 0.78)
        case (true,  true,  true,  false, false): return r("K", 0.55)   // thumb between index+middle
        case (false, true,  true,  true,  false): return r("W", 0.78)
        case (false, true,  true,  false, false):
            return indexMiddleSpread ? r("V", 0.78) : r("U", 0.7)
        case (false, true,  false, false, false): return r("D", 0.62)   // index up (vs G/1)
        default:
            // Recognizable hand, but not a shape we read confidently.
            return r("", 0.3)
        }
    }

    /// Whether the thumb tip and index tip are pinched together (tips touching),
    /// normalized by palm length. Pure — reused by the camera "pinch to talk"
    /// trigger so it stays consistent with the F/O handshape geometry above.
    static func isPinching(_ s: HandSample) -> Bool {
        guard let wrist = s.p(.wrist), let midMCP = s.p(.middleMCP),
              let tt = s.p(.thumbTip), let it = s.p(.indexTip) else { return false }
        let scale = max(dist(wrist, midMCP), 0.0001)
        return dist(tt, it) < 0.45 * scale
    }

    /// A deliberate pinch *trigger*: thumb+index pinched AND the middle/ring/little
    /// fingers NOT extended (a closed-hand pinch). Stricter than `isPinching` so it
    /// isn't confused with the F handshape (three fingers extended) or an open hand.
    static func isPinchTrigger(_ s: HandSample) -> Bool {
        guard isPinching(s), let wrist = s.p(.wrist) else { return false }
        let middle = fingerExtended(s, .middleMCP, .middlePIP, .middleTip, wrist: wrist)
        let ring   = fingerExtended(s, .ringMCP, .ringPIP, .ringTip, wrist: wrist)
        let little = fingerExtended(s, .littleMCP, .littlePIP, .littleTip, wrist: wrist)
        return !middle && !ring && !little
    }
}

/// Pure temporal gate for a deliberate pinch trigger: fires ONCE when a pinch is
/// held for `requiredHold` frames, then re-arms only after the hand opens for
/// `releaseFrames` frames (so a sustained pinch can't repeat-fire). Foundation-
/// only → unit-testable with `swiftc`, like SignAssembler.
struct PinchGate {
    var requiredHold = 4
    var releaseFrames = 3
    private var held = 0
    private var openCount = 0
    private var armed = true

    /// Feed one frame's pinch state; returns true exactly once per deliberate pinch.
    mutating func feed(_ pinching: Bool) -> Bool {
        if pinching {
            openCount = 0
            guard armed else { return false }
            held += 1
            if held >= requiredHold { armed = false; held = 0; return true }
        } else {
            held = 0
            openCount += 1
            if openCount >= releaseFrames { armed = true }
        }
        return false
    }

    mutating func reset() { held = 0; openCount = 0; armed = true }
}
