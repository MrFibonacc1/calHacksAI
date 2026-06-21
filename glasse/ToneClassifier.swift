//
//  ToneClassifier.swift
//  glasse
//
//  Tone / emotion hint for live captions (deaf / hard-of-hearing users).
//
//  Deaf and hard-of-hearing readers get the *words* from captions but lose
//  prosody — whether something was a question, exclaimed, urgent, warm, or sour.
//  This adds a small, honest tone hint next to the caption.
//
//  Honest framing (matches the rest of the app): the tone is estimated from the
//  *text* — Apple's on-device NaturalLanguage sentiment plus light punctuation /
//  keyword cues — NOT from the audio. It can hint at prosody but it cannot truly
//  hear sarcasm or tone of voice, so it is shown as a best-guess hint and
//  `.neutral` shows nothing at all. Everything runs on-device; no audio, text,
//  or frames leave the phone.
//
//  Calibrated for precision over recall (the safe choice for an accessibility
//  hint): `.urgent` fires on clear warnings, not on every "help" / "stop", so it
//  may miss a non-exclaimed shout; `.negative` is intentionally rare — only
//  strongly negative text trips it, because Apple's sentiment baseline for
//  ordinary neutral speech is ~ -0.6. False reassurance or false alarm is worse
//  than no hint, so when unsure we stay `.neutral`.
//
//  Structure mirrors the Sign modules: `ToneHeuristics` is pure (Foundation
//  only) so it is unit-testable with `swiftc`; `ToneClassifier` wraps the
//  on-device sentiment model; the SwiftUI tint lives in `Tone+Tint.swift`.
//

import Foundation
import NaturalLanguage

/// A coarse, best-guess tone for one spoken line. Deliberately small and honest.
/// `.neutral` is the default and renders no pill.
enum Tone: String, CaseIterable, Sendable {
    case neutral, positive, negative, question, excited, urgent

    var label: String {
        switch self {
        case .neutral:  return "Neutral"
        case .positive: return "Positive"
        case .negative: return "Negative"
        case .question: return "Question"
        case .excited:  return "Excited"
        case .urgent:   return "Urgent"
        }
    }

    /// SF Symbol for the pill.
    var symbol: String {
        switch self {
        case .neutral:  return "waveform"
        case .positive: return "face.smiling"
        case .negative: return "cloud.rain"
        case .question: return "questionmark.circle.fill"
        case .excited:  return "sparkles"
        case .urgent:   return "exclamationmark.triangle.fill"
        }
    }

    /// We don't clutter the UI with a pill for the default case.
    var showsPill: Bool { self != .neutral }

    /// Lens-card title carrying the tone hint (the deaf user reads this on the lens).
    var lensTitle: String { self == .neutral ? "Captions" : "Captions · \(label)" }

    /// VoiceOver prefix so low-vision caption users hear the tone too.
    var spokenPrefix: String { self == .neutral ? "" : "Tone: \(label). " }
}

/// Pure tone logic — Foundation only, no NaturalLanguage / SwiftUI — so it can be
/// unit-tested with `swiftc` the same way `SignClassifier` / `SignAssembler` are.
enum ToneHeuristics {
    /// Phrases that are essentially only ever warnings — flagged urgent on their
    /// own. Kept deliberately narrow: words like "help" / "stop" / "fire" are far
    /// too common in ordinary speech ("thanks for your help", "the next stop
    /// is…") to flag unconditionally, so they live in `urgentWhenExclaimed`.
    /// Whole-word/phrase matched, case-insensitive.
    static let urgentPhrases: [String] = [
        "watch out", "look out", "behind you",
        "call 911", "call an ambulance", "call the police"
    ]

    /// Common danger words that read as urgent only when *exclaimed* ("Help!",
    /// "Stop!", "Fire!"). Requiring the "!" keeps precision high and, as a bonus,
    /// suppresses calm negations ("there's no emergency", "the danger has passed")
    /// which carry no exclamation. Trade-off: a non-exclaimed shout is missed —
    /// an accepted recall cost for the one safety-relevant pill.
    static let urgentWhenExclaimed: [String] = [
        "help", "stop", "fire", "emergency", "danger", "careful", "hurry", "run"
    ]

    static let positiveThreshold = 0.35
    // Apple's on-device sentiment returns ~ -0.6 as a *baseline* for ordinary
    // neutral speech (measured: "turn left at the corner", "my name is Sarah",
    // etc. all score -0.6), and only strongly negative text reaches the extreme.
    // So we require a strong magnitude for `.negative` to avoid mislabeling
    // neutral speech as negative — high precision over recall, the safe tradeoff
    // for an accessibility hint. Positive separates cleanly from the baseline.
    static let negativeThreshold = -0.9

    /// The most recent thing said. Handles both transcript shapes:
    ///  • Deepgram diarized — multiple "Speaker N:" lines separated by "\n".
    ///  • Apple fallback — one growing, newline-free line (committed + latest).
    /// Takes the last line, strips any "Speaker N:" label, then returns just the
    /// trailing *sentence* — so on the single-line Apple path an early cue (e.g.
    /// "I need help.") can't latch the tone for the rest of the session.
    static func latestUtterance(_ transcript: String) -> String {
        guard var line = transcript
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init) else { return "" }
        // Strip a leading "Speaker 12: " label if present.
        if let colon = line.firstIndex(of: ":"),
           line[line.startIndex..<colon].lowercased().hasPrefix("speaker") {
            line = String(line[line.index(after: colon)...])
        }
        return lastSentence(of: line.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The last sentence of `text`, keeping its trailing terminator so the
    /// question/excited cues still see the final "?"/"!". Returns the whole
    /// (trimmed) string when there's no terminator.
    static func lastSentence(of text: String) -> String {
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { sentences.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences.last ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Classify a single utterance. `sentiment` is Apple's NaturalLanguage score
    /// in [-1, 1] (nil when there's no signal). Order matters: the most
    /// safety-relevant cue (urgent) wins, then grammatical (question), then
    /// emphatic (excited), then overall sentiment.
    static func classify(text raw: String, sentiment: Double?) -> Tone {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .neutral }
        let lower = text.lowercased()
        let score = sentiment ?? 0
        let bang = text.hasSuffix("!")

        // Urgent is keyword-driven (sentiment is too noisy on short utterances):
        // unambiguous warning phrases always, common danger words only when
        // exclaimed — high precision so the red pill doesn't cry wolf.
        if urgentPhrases.contains(where: { containsPhrase(lower, $0) })
            || (bang && urgentWhenExclaimed.contains(where: { containsPhrase(lower, $0) })) {
            return .urgent
        }
        if text.hasSuffix("?") { return .question }
        if bang { return .excited }
        if score >= positiveThreshold { return .positive }
        if score <= negativeThreshold { return .negative }
        return .neutral
    }

    /// Combine the structural cues (urgent / question / excited) with an external
    /// sentiment LABEL — used when sentiment comes from Deepgram's Read API rather
    /// than Apple's numeric score (their score scales differ, so we trust their
    /// label, not a threshold). Structural cues still win; the label only decides
    /// positive vs negative when the line is otherwise neutral.
    static func classify(text raw: String, sentimentLabel: String?) -> Tone {
        let structural = classify(text: raw, sentiment: nil)
        guard structural == .neutral else { return structural }
        switch sentimentLabel?.lowercased() {
        case "positive": return .positive
        case "negative": return .negative
        default:         return .neutral
        }
    }

    // MARK: - helpers

    /// Whole-word / phrase containment, so "helps" doesn't match the cue "help".
    private static func containsPhrase(_ haystackLower: String, _ needleLower: String) -> Bool {
        guard !needleLower.isEmpty else { return false }
        let normalized = haystackLower
            .split { !($0.isLetter || $0.isNumber || $0 == " ") }
            .joined(separator: " ")
        return " \(normalized) ".contains(" \(needleLower) ")
    }
}

/// Runs Apple's on-device NaturalLanguage sentiment, then applies `ToneHeuristics`.
/// Stateless (a tagger is created per call; NaturalLanguage caches the model
/// process-wide). Callers invoke it on the throttled caption cadence — not per
/// partial result — to keep the sentiment inference off the per-keystroke path.
/// Under the project's default MainActor isolation this runs on the main actor.
enum ToneClassifier {
    /// Tone for one utterance (already extracted via `ToneHeuristics.latestUtterance`).
    static func classify(_ utterance: String) -> Tone {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .neutral }
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
        let score = tag.flatMap { Double($0.rawValue) }
        return ToneHeuristics.classify(text: text, sentiment: score)
    }
}
