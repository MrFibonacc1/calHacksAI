//
//  SignMotionMatcher.swift
//  glasse
//
//  Pure, dependency-free core for the experimental whole-word sign recognizer.
//  A sign is captured as a SEQUENCE of hand-pose frames (a feature vector per
//  frame). Recognition is template matching: the user records each vocabulary
//  word once in "teach mode", and at read-time an incoming motion is compared to
//  every stored template with Dynamic Time Warping (DTW) — the closest template,
//  if close enough, is the recognized word.
//
//  This file imports only Foundation + CoreGraphics (HandJoint comes from the
//  equally-pure SignClassifier.swift), so the matching math can be compiled and
//  unit-tested with `swiftc` off-device. SignVocabReader.swift adds the Vision
//  camera layer; SignTemplateStore.swift persists the templates.
//
//  Honesty: this is single-signer, small-vocabulary, deliberate-signing template
//  matching — a best-effort experiment, NOT a reliable ASL transcriber. It always
//  surfaces a confidence level and never claims certainty.
//

import Foundation
import CoreGraphics

/// One frame of a sign: a fixed-length feature vector (normalized hand landmarks
/// plus a gross location cue). Pure data.
struct MotionFrame: Codable, Equatable, Sendable {
    let features: [Double]
}

/// A recorded reference for one vocabulary word.
struct SignTemplate: Codable, Equatable, Sendable {
    let label: String
    let frames: [MotionFrame]
}

/// The result of matching an incoming motion against the templates.
struct SignMatch: Equatable, Sendable {
    let label: String
    let distance: Double
    let confidence: Double   // 0...1 (closeness + separation from the runner-up)
}

enum SignMotionMatcher {

    /// Stable joint ordering for the feature vector (21 joints from Vision).
    static let jointOrder: [HandJoint] = HandJoint.allCases

    /// Build a per-frame feature vector from one hand's landmarks: each joint as an
    /// (x,y) offset from the wrist, scaled by palm length (translation/scale/!size
    /// invariant → captures handshape + orientation), plus the wrist's raw position
    /// so gross location (high near the face vs low at the chest) is preserved.
    /// Returns nil if the wrist/palm reference joints are missing.
    static func featureVector(points: [HandJoint: CGPoint]) -> [Double]? {
        guard let wrist = points[.wrist], let mid = points[.middleMCP] else { return nil }
        let scale = max(hypot(mid.x - wrist.x, mid.y - wrist.y), 0.0001)
        var f: [Double] = []
        f.reserveCapacity(jointOrder.count * 2 + 2)
        for j in jointOrder {
            if let p = points[j] {
                f.append(Double((p.x - wrist.x) / scale))
                f.append(Double((p.y - wrist.y) / scale))
            } else {
                f.append(0); f.append(0)
            }
        }
        f.append(Double(wrist.x)); f.append(Double(wrist.y))   // gross location
        return f
    }

    /// Resample a variable-length sequence to a fixed number of frames with linear
    /// interpolation, so query and templates are length-comparable and bounded.
    static func resample(_ frames: [MotionFrame], to count: Int) -> [MotionFrame] {
        guard count > 0 else { return [] }
        guard frames.count > 1 else {
            return frames.isEmpty ? [] : Array(repeating: frames[0], count: count)
        }
        var out: [MotionFrame] = []
        out.reserveCapacity(count)
        for k in 0..<count {
            let pos = Double(k) * Double(frames.count - 1) / Double(count - 1)
            let lo = Int(pos.rounded(.down))
            let hi = min(lo + 1, frames.count - 1)
            let frac = pos - Double(lo)
            let fa = frames[lo].features, fb = frames[hi].features
            let n = min(fa.count, fb.count)
            var f = [Double](); f.reserveCapacity(n)
            for i in 0..<n { f.append(fa[i] + (fb[i] - fa[i]) * frac) }
            out.append(MotionFrame(features: f))
        }
        return out
    }

    /// Euclidean distance between two frames' feature vectors.
    static func frameDistance(_ a: MotionFrame, _ b: MotionFrame) -> Double {
        let n = min(a.features.count, b.features.count)
        var s = 0.0
        for i in 0..<n { let d = a.features[i] - b.features[i]; s += d * d }
        return s.squareRoot()
    }

    /// Dynamic Time Warping distance between two frame sequences, normalized by the
    /// total path length so different-length signs stay comparable.
    static func dtw(_ a: [MotionFrame], _ b: [MotionFrame]) -> Double {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return .infinity }
        var dp = Array(repeating: Array(repeating: Double.infinity, count: m + 1), count: n + 1)
        dp[0][0] = 0
        for i in 1...n {
            for j in 1...m {
                let cost = frameDistance(a[i - 1], b[j - 1])
                dp[i][j] = cost + Swift.min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
            }
        }
        return dp[n][m] / Double(n + m)
    }

    /// Classify a captured sequence against the templates. Returns the closest
    /// match if its distance is within `maxDistance`, else nil (unknown). Confidence
    /// blends absolute closeness with separation from the runner-up.
    static func classify(_ seq: [MotionFrame],
                         templates: [SignTemplate],
                         maxDistance: Double,
                         resampleTo: Int = 16) -> SignMatch? {
        guard !templates.isEmpty, !seq.isEmpty else { return nil }
        let q = resample(seq, to: resampleTo)
        var scored: [(label: String, dist: Double)] = []
        for tpl in templates {
            let r = resample(tpl.frames, to: resampleTo)
            scored.append((tpl.label, dtw(q, r)))
        }
        scored.sort { $0.dist < $1.dist }
        let best = scored[0]
        guard best.dist <= maxDistance else { return nil }

        let closeness = Swift.max(0, 1 - best.dist / maxDistance)
        let separation: Double = scored.count > 1
            ? Swift.max(0, Swift.min(1, (scored[1].dist - best.dist) / Swift.max(best.dist, 0.0001)))
            : 1
        let confidence = Swift.max(0, Swift.min(1, 0.5 * closeness + 0.5 * separation))
        return SignMatch(label: best.label, distance: best.dist, confidence: confidence)
    }
}
