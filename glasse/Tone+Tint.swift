//
//  Tone+Tint.swift
//  glasse
//
//  SwiftUI display tint for `Tone`, kept out of `ToneClassifier.swift` so the
//  classification logic there stays Foundation-only and unit-testable with `swiftc`.
//

import SwiftUI

extension Tone {
    /// Pill color. Chosen for contrast on the captions card and for the lens.
    var tint: Color {
        switch self {
        case .neutral:  return .secondary
        case .positive: return .green
        case .negative: return .indigo
        case .question: return .teal
        case .excited:  return .orange
        case .urgent:   return .red
        }
    }
}
