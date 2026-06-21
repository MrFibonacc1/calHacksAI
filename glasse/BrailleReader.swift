//
//  BrailleReader.swift
//  glasse
//
//  On-device Braille → text. Uses a Core ML braille-CELL detector (DotNeuralNet,
//  YOLOv8, MIT — exported to BrailleYOLO.mlmodelc) where each detection box IS one
//  braille cell and its class label is the 6-bit dot pattern (e.g. "100100", dots
//  1–6). We assemble the boxes into reading order, turn each pattern into its Unicode
//  braille character, and Grade-1 decode to Latin text — all deterministic + offline.
//
//  This is the PRIMARY braille path. ContentView's `read_text` falls back to Claude
//  vision when this finds no confident braille grid — and Claude also covers Grade-2
//  (contracted) braille, which this literal Grade-1 reader does NOT expand.
//
//  Like ObjectDetector, Core ML inference does NOT run on the iOS Simulator (device
//  only). If BrailleYOLO.mlmodelc isn't in the bundle yet, `modelAvailable` is false
//  and `read(...)` returns `.empty`, so read_text cleanly falls back to Claude. See
//  BRAILLE_SETUP.md for the one-time model export.
//

import Foundation
import Vision
import CoreML
import UIKit
import Observation

struct BrailleResult: Sendable {
    let text: String
    let cellCount: Int        // detected cells (density signal)
    let confidence: Double    // mean detector confidence 0–1 (0 if nothing found)
    static let empty = BrailleResult(text: "", cellCount: 0, confidence: 0)
}

@Observable
@MainActor
final class BrailleReader {
    let modelAvailable: Bool
    let loadError: String

    @ObservationIgnored private var vnModel: VNCoreMLModel?
    @ObservationIgnored private var isProcessing = false

    init() {
        guard let url = Bundle.main.url(forResource: "BrailleYOLO", withExtension: "mlmodelc") else {
            modelAvailable = false
            loadError = "BrailleYOLO.mlmodelc not in bundle — export DotNeuralNet and add it (see BRAILLE_SETUP.md)."
            return
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndGPU   // match ObjectDetector; avoids ANE quirks
            let model = try MLModel(contentsOf: url, configuration: config)
            vnModel = try VNCoreMLModel(for: model)
            modelAvailable = true
            loadError = ""
        } catch {
            modelAvailable = false
            loadError = "\(error)"
        }
    }

    /// Detect + decode braille off the main actor. Returns `.empty` if the model is
    /// missing or no braille is found, so callers fall back to Claude.
    func read(_ image: UIImage) async -> BrailleResult {
        guard !isProcessing, let vnModel, let cg = image.cgImage else { return .empty }
        isProcessing = true
        defer { isProcessing = false }
        let model = vnModel
        return await Task.detached(priority: .userInitiated) {
            BrailleReader.detect(cg, with: model)
        }.value
    }

    // MARK: - Detection (off the main actor)

    nonisolated private static func detect(_ cg: CGImage, with model: VNCoreMLModel) -> BrailleResult {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results as? [VNRecognizedObjectObservation],
              !obs.isEmpty else { return .empty }
        return decode(obs)
    }

    /// Assemble detected cells into reading order (port of DotNeuralNet's
    /// parse_xywh_and_class) and Grade-1 decode. Vision boxes are normalized with the
    /// origin at the BOTTOM-left, so higher on the page = larger midY → rows sort by
    /// DESCENDING midY, and each row left→right by ascending midX.
    nonisolated private static func decode(_ obs: [VNRecognizedObjectObservation]) -> BrailleResult {
        let cells: [(rect: CGRect, pattern: String, conf: Float)] = obs.compactMap { o in
            guard let label = o.labels.first else { return nil }
            return (o.boundingBox, label.identifier, label.confidence)
        }
        guard !cells.isEmpty else { return .empty }

        let meanHeight = cells.map { $0.rect.height }.reduce(0, +) / CGFloat(cells.count)
        let gap = max(meanHeight / 2, 0.0001)
        let sorted = cells.sorted { $0.rect.midY > $1.rect.midY }   // top → bottom

        var lines: [[(rect: CGRect, pattern: String, conf: Float)]] = []
        var current: [(rect: CGRect, pattern: String, conf: Float)] = []
        var lastY: CGFloat?
        for cell in sorted {
            if let y = lastY, (y - cell.rect.midY) > gap {
                lines.append(current); current = []
            }
            current.append(cell); lastY = cell.rect.midY
        }
        if !current.isEmpty { lines.append(current) }

        var braille = ""
        var confSum: Double = 0
        for line in lines {
            for cell in line.sorted(by: { $0.rect.midX < $1.rect.midX }) {
                braille.unicodeScalars.append(unicodeBraille(for: cell.pattern))
                confSum += Double(cell.conf)
            }
            braille.unicodeScalars.append(Unicode.Scalar(0x0A)!)   // newline between rows
        }

        let text = grade1Text(from: braille)
        let confidence = confSum / Double(cells.count)
        return BrailleResult(text: text, cellCount: cells.count, confidence: confidence)
    }

    /// 6-bit dot pattern ("100100", dots 1–6) → Unicode braille scalar (U+2800 base).
    nonisolated private static func unicodeBraille(for pattern: String) -> Unicode.Scalar {
        var bits = 0
        for (i, ch) in pattern.prefix(6).enumerated() where ch == "1" { bits |= (1 << i) }
        return Unicode.Scalar(0x2800 + bits) ?? Unicode.Scalar(0x2800)!
    }

    // MARK: - Grade-1 (uncontracted) decode

    /// Unicode braille scalar value → Latin letter (lowercase).
    nonisolated private static let letters: [UInt32: Character] = [
        0x2801: "a", 0x2803: "b", 0x2809: "c", 0x2819: "d", 0x2811: "e",
        0x280B: "f", 0x281B: "g", 0x2813: "h", 0x280A: "i", 0x281A: "j",
        0x2805: "k", 0x2807: "l", 0x280D: "m", 0x281D: "n", 0x2815: "o",
        0x280F: "p", 0x281F: "q", 0x2817: "r", 0x280E: "s", 0x281E: "t",
        0x2825: "u", 0x2827: "v", 0x283A: "w", 0x282D: "x", 0x283D: "y", 0x2835: "z",
    ]
    /// a–j map to digits 1–0 after a number sign.
    nonisolated private static let digits: [Character: Character] = [
        "a": "1", "b": "2", "c": "3", "d": "4", "e": "5",
        "f": "6", "g": "7", "h": "8", "i": "9", "j": "0",
    ]
    nonisolated private static let punctuation: [UInt32: Character] = [
        0x2802: ",", 0x2806: ";", 0x2812: ":", 0x2832: ".",
        0x2816: "!", 0x2826: "(", 0x2834: ")", 0x2814: "?",
    ]

    private static let numberSign: UInt32 = 0x283C
    private static let capitalSign: UInt32 = 0x2820

    /// Decode Unicode braille chars → Latin text, honoring number-sign (following a–j
    /// become digits until a space) and capital-sign (next letter uppercased). Unknown
    /// cells become "?". Blank cell (U+2800) is a space.
    nonisolated private static func grade1Text(from braille: String) -> String {
        var result = ""
        var numberMode = false
        var capitalNext = false
        for scalar in braille.unicodeScalars {
            let v = scalar.value
            if v == 0x0A { result.append("\n"); numberMode = false; continue }
            if v == 0x2800 { result.append(" "); numberMode = false; continue }
            if v == numberSign { numberMode = true; continue }
            if v == capitalSign { capitalNext = true; continue }
            if numberMode, let base = letters[v], let d = digits[base] {
                result.append(d); continue
            }
            if let base = letters[v] {
                result.append(capitalNext ? Character(base.uppercased()) : base)
                capitalNext = false
                continue
            }
            if let p = punctuation[v] { result.append(p); continue }
            result.append("?")   // unrecognised cell
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
