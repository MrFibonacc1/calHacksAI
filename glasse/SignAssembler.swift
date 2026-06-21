//
//  SignAssembler.swift
//  glasse
//
//  Pure temporal layer for the fingerspelling reader: turns a stream of
//  per-frame SignReadings into committed letters and assembled words. A letter
//  is committed only after it's held steady for `requiredStable` frames (and not
//  immediately repeated); an open hand or an absent hand for `boundaryFrames`
//  inserts a word break. No Vision / UIKit imports, so it's unit-testable
//  off-device with `swiftc` (like SignClassifier).
//

import Foundation

struct SignAssembler {
    private(set) var transcript = ""
    private(set) var currentLetter = ""
    private(set) var currentLevel: ConfidenceLevel = .low
    private(set) var handPresent = false

    private var words: [String] = []
    private var current = ""
    private var stableLetter = ""
    private var stableCount = 0
    private var lastCommitted = ""
    private var noHandFrames = 0
    private var openHandFrames = 0

    let requiredStable: Int
    let boundaryFrames: Int

    init(requiredStable: Int = 6, boundaryFrames: Int = 6) {
        self.requiredStable = requiredStable
        self.boundaryFrames = boundaryFrames
    }

    mutating func reset() {
        self = SignAssembler(requiredStable: requiredStable, boundaryFrames: boundaryFrames)
    }

    /// Feed one frame's classification. `present` = a hand was detected at all.
    mutating func feed(_ reading: SignReading, present: Bool) {
        handPresent = present

        if !present {
            currentLetter = ""; currentLevel = .low; stableLetter = ""; stableCount = 0; openHandFrames = 0
            noHandFrames += 1
            if noHandFrames == boundaryFrames { commitSpace() }
            return
        }
        noHandFrames = 0

        if reading.isOpenHand {
            currentLetter = ""; currentLevel = .low; stableLetter = ""; stableCount = 0
            openHandFrames += 1
            if openHandFrames == boundaryFrames { commitSpace() }
            return
        }
        openHandFrames = 0

        currentLetter = reading.letter
        currentLevel = reading.level

        // Only commit deliberate, medium-or-better letters held steady.
        guard !reading.letter.isEmpty, reading.level != .low else {
            stableLetter = ""; stableCount = 0
            return
        }
        if reading.letter == stableLetter {
            stableCount += 1
        } else {
            stableLetter = reading.letter
            stableCount = 1
        }
        if stableCount == requiredStable && reading.letter != lastCommitted {
            current += reading.letter
            lastCommitted = reading.letter
            rebuild()
        }
    }

    private mutating func commitSpace() {
        if !current.isEmpty { words.append(current); current = ""; rebuild() }
        lastCommitted = ""   // allow the same letter to start the next word
    }

    private mutating func rebuild() {
        var all = words
        if !current.isEmpty { all.append(current) }
        var t = all.joined(separator: " ")
        if t.count > 80 { t = "…" + t.suffix(80) }
        transcript = t
    }
}
