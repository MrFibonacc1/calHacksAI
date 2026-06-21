//
//  SpeechVocabulary.swift
//  glasse
//
//  Words and phrases the app expects to hear, used to BIAS speech-to-text toward
//  them so it recognizes the terms that actually matter more reliably:
//    • Deepgram Nova-3 "keyterm" prompting (streaming STT), and
//    • Apple's `SFSpeechRecognitionRequest.contextualStrings` (on-device fallback).
//
//  Focused on the wake word and the app's distinctive command vocabulary —
//  especially rarer terms ("fingerspelling", "braille") that generic recognizers
//  often mis-hear. Kept small on purpose: over-boosting hurts general accuracy.
//
//  Pure (Foundation only) so it stays unit-testable like the other speech helpers.
//

import Foundation

enum SpeechVocabulary {
    /// Terms to boost. The wake word first, then the command vocabulary.
    static let terms: [String] = [
        "glasses",                 // wake word
        "captions", "live captions",
        "fingerspelling", "sign language", "braille",
        "describe", "what's in front of me",
        "read text",
        "identify objects",
        "navigate", "directions",
        "text to speech",
        "translate",
    ]
}
