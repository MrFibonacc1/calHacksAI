//
//  FingerspellGuide.swift
//  glasse
//
//  Pure, dependency-free ASL fingerspelling guide: maps each letter / digit to a
//  short text description of how to form the static handshape, and turns a spoken
//  phrase into an ordered sequence of fingerspelling steps the wearer can copy.
//
//  This file imports ONLY Foundation (no SwiftUI / Speech), so the mapping +
//  tokenizing logic can be compiled and unit-tested with `swiftc` off-device —
//  the same pattern as SignClassifier.swift.
//
//  Scope & honesty: this teaches the static fingerspelling ALPHABET (spelling a
//  word out letter by letter) so a hearing wearer can sign names / words back to
//  a Deaf person. It is NOT a translation of speech into fluent ASL — ASL has its
//  own grammar and is not word-for-word English. The two motion letters (J, Z)
//  describe the movement; everything is framed as a best-effort coach.
//

import Foundation

/// One step in spelling out a phrase: a letter to sign, a digit, a word-gap, or a
/// character with no fingerspelling handshape (skipped with a note).
struct FingerspellStep: Equatable {
    enum Kind: Equatable {
        case sign(String)            // a whole word with a known ASL sign (play its clip)
        case letter(Character)       // A–Z (fingerspelled handshape)
        case digit(Character)        // 0–9
        case space                   // word boundary
        case unsupported(Character)  // punctuation / emoji — no handshape
    }
    let kind: Kind

    /// What to show big on screen / the lens.
    var glyph: String {
        switch kind {
        case .sign(let w):   return w.uppercased()
        case .letter(let c): return String(c).uppercased()
        case .digit(let c):  return String(c)
        case .space:         return "␣"
        case .unsupported(let c): return String(c)
        }
    }

    /// How to form the handshape / sign (or what to do for spaces / unsupported chars).
    var cue: String {
        switch kind {
        case .sign(let w):   return "Make the ASL sign for “\(w.uppercased())”."
        case .letter(let c):
            let key = String(c).uppercased().first ?? c
            return FingerspellGuide.handshapes[key] ?? "Spell this letter."
        case .digit(let c):  return FingerspellGuide.numbers[c] ?? "Show this number."
        case .space:         return "Word break — drop your hand briefly, then start the next word."
        case .unsupported:   return "No fingerspelling handshape for this — skip it."
        }
    }

    /// A space and unsupported characters aren't content to copy; the UI can dwell
    /// less on them.
    var isSignable: Bool {
        switch kind { case .sign, .letter, .digit: return true; default: return false }
    }
}

enum FingerspellGuide {

    /// Static ASL fingerspelling alphabet — concise, front-facing handshape cues.
    static let handshapes: [Character: String] = [
        "A": "Make a fist; rest your thumb flat against the side of your index finger.",
        "B": "Hold your hand flat, four fingers straight up and together, thumb folded across your palm.",
        "C": "Curve your fingers and thumb into the shape of a letter C.",
        "D": "Point your index finger up; touch your thumb to the tips of the other curled fingers.",
        "E": "Curl all four fingers down so their tips meet your thumb; thumb tucked underneath.",
        "F": "Touch your thumb and index fingertips into a circle; the other three fingers point up.",
        "G": "Point your index finger and thumb sideways, parallel, like a small gap.",
        "H": "Point your index and middle fingers out sideways, together.",
        "I": "Make a fist with just your little (pinky) finger pointing straight up.",
        "J": "Form an I, then draw the shape of a J in the air with your pinky. (motion)",
        "K": "Index and middle fingers up in a V; rest your thumb between them.",
        "L": "Index finger up and thumb out to the side, forming an L.",
        "M": "Fold your first three fingers over your thumb, so the thumb peeks under three fingers.",
        "N": "Fold your first two fingers over your thumb, so the thumb peeks under two fingers.",
        "O": "Bring all your fingertips and thumb together into an O.",
        "P": "Make a K shape, then point it downward.",
        "Q": "Make a G shape, then point it downward.",
        "R": "Cross your index and middle fingers, pointing up.",
        "S": "Make a fist with your thumb across the front of your fingers.",
        "T": "Make a fist with your thumb poking up between your index and middle fingers.",
        "U": "Point your index and middle fingers up, together.",
        "V": "Point your index and middle fingers up, spread apart into a V.",
        "W": "Point your index, middle, and ring fingers up and spread, forming a W.",
        "X": "Make a fist with your index finger up and bent into a hook.",
        "Y": "Stick your thumb and little finger out, other fingers folded (the “hang loose” shape).",
        "Z": "Point your index finger up, then draw the shape of a Z in the air. (motion)",
    ]

    /// ASL number handshapes 0–9 (palm facing the person you are signing to).
    static let numbers: [Character: String] = [
        "0": "Bring all your fingertips and thumb together into an O.",
        "1": "Point your index finger straight up.",
        "2": "Point your index and middle fingers up in a V.",
        "3": "Point your thumb, index, and middle fingers up.",
        "4": "Hold four fingers up and spread, thumb folded across your palm.",
        "5": "Hold all five fingers up and spread.",
        "6": "Touch your little finger to your thumb; index, middle, and ring fingers up.",
        "7": "Touch your ring finger to your thumb; index, middle, and little fingers up.",
        "8": "Touch your middle finger to your thumb; index, ring, and little fingers up.",
        "9": "Touch your index finger to your thumb; the other three fingers up.",
    ]

    /// Turn a spoken phrase into an ordered list of steps. Words whose uppercased
    /// form is in `signs` become a single whole-word `.sign` step (the lens plays
    /// that sign's clip); every other word is fingerspelled letter by letter. Pure
    /// and deterministic: splitting on whitespace drops empty runs, so leading,
    /// trailing, and repeated spaces collapse to single word-breaks on their own.
    static func steps(for text: String, signs: Set<String> = []) -> [FingerspellStep] {
        var out: [FingerspellStep] = []
        for word in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            if !out.isEmpty { out.append(FingerspellStep(kind: .space)) }
            let w = String(word)
            if signs.contains(w.uppercased()) {
                out.append(FingerspellStep(kind: .sign(w)))
                continue
            }
            for ch in w {
                if ch.isLetter, let a = ch.unicodeScalars.first, a.isASCII {
                    out.append(FingerspellStep(kind: .letter(ch)))
                } else if ch.isNumber, "0"..."9" ~= ch {
                    out.append(FingerspellStep(kind: .digit(ch)))
                } else {
                    out.append(FingerspellStep(kind: .unsupported(ch)))
                }
            }
        }
        return out
    }
}
