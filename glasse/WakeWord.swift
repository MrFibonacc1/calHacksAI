//
//  WakeWord.swift
//  glasse
//
//  Hands-free activation: detect the wake word "glasses" in a speech transcript
//  and pull out any command spoken in the same breath ("glasses turn on captions").
//
//  Pure (Foundation only) so it is unit-testable with `swiftc`, like the Sign /
//  Tone modules. Normalization makes matching case- and punctuation-insensitive,
//  so "Glasses!" matches the same as "glasses".
//

import Foundation

enum WakeWord {
    /// Accepted wake word. The single word "glasses" is the easiest possible
    /// trigger and STT transcribes it reliably — at the cost of false-firing on
    /// ordinary speech ("where are my glasses", "nice glasses"). This is a
    /// deliberate ease-over-precision choice; the feature is opt-in via a toggle.
    static let triggers: [String] = [
        "glasses",
    ]

    /// Set used for always-on scanning of OTHER people's speech (captions mode).
    /// Same single word — note this WILL pick up any nearby mention of "glasses".
    static let strictTriggers: [String] = [
        "glasses",
    ]

    /// Result of scanning a transcript for the wake phrase.
    /// `nil`            → no wake phrase present.
    /// `.some("")`      → wake phrase present, nothing said after it (just listen).
    /// `.some(command)` → wake phrase plus a command spoken in the same utterance.
    static func match(_ text: String, strict: Bool = false) -> String? {
        let norm = normalized(text)                      // " glasses turn on captions "
        var earliest: String.Index? = nil
        var command: String? = nil
        for trigger in (strict ? strictTriggers : triggers) {
            let needle = " " + bareNormalized(trigger) + " "
            guard let r = norm.range(of: needle) else { continue }
            if earliest == nil || r.lowerBound < earliest! {
                earliest = r.lowerBound
                command = String(norm[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return command
    }

    /// Convenience: is the wake phrase present at all?
    static func isPresent(in text: String, strict: Bool = false) -> Bool { match(text, strict: strict) != nil }

    /// Scan a (possibly multi-line, diarized) transcript and return the command
    /// that follows the MOST RECENT wake phrase — matched within a single line so
    /// it can't run on into another speaker's words. nil if no wake phrase, or ""
    /// if the wake phrase had nothing after it. `strict` (default) uses the
    /// stricter trigger set, which matters when scanning a whole room's speech.
    static func commandInTranscript(_ transcript: String, strict: Bool = true) -> String? {
        for line in transcript.split(separator: "\n").suffix(6).reversed() {
            if let cmd = match(String(line), strict: strict) { return cmd }
        }
        return nil
    }

    // MARK: - normalization

    /// Lowercased, punctuation collapsed to single spaces, space-padded so all
    /// matching happens on word boundaries (" glasses " can't match inside a
    /// larger token).
    private static func normalized(_ s: String) -> String {
        let collapsed = s.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .joined(separator: " ")
        return " \(collapsed) "
    }

    /// Normalized trigger without the outer padding (it's added at match time).
    private static func bareNormalized(_ s: String) -> String {
        s.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .joined(separator: " ")
    }
}
