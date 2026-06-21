//
//  ObjectDetector.swift
//  glasse
//
//  On-device scene understanding using a prebuilt ADE20K semantic-segmentation
//  model (ISANet, MIT). The model labels every pixel with one of 150 real-world
//  classes (road, sidewalk, door, stairs, person, car, wall, floor, …). We read
//  the most common class in the central region — "what's roughly ahead" — and
//  surface it as a single word.
//
//  Note: Core ML inference does NOT run on the iOS Simulator ("Failed to create
//  espresso context") — this works on a real device only.
//

import Foundation
import Vision
import CoreML
import UIKit
import Observation

@Observable
@MainActor
final class ObjectDetector {
    struct Detection: Identifiable, Sendable {
        let id = UUID()
        let label: String
        let confidence: Float   // fraction of the central region this class covers (0–1)
    }

    var detections: [Detection] = []

    /// The single most prominent thing directly ahead, as one word.
    var topLabel: String { detections.first?.label ?? "" }

    let modelAvailable: Bool
    let loadError: String

    @ObservationIgnored private var vnModel: VNCoreMLModel?
    @ObservationIgnored private var lastProcess = Date.distantPast
    @ObservationIgnored private var isProcessing = false

    init() {
        guard let url = Bundle.main.url(forResource: "ISANet", withExtension: "mlmodelc") else {
            modelAvailable = false
            loadError = "ISANet.mlmodelc not found in bundle"
            return
        }
        do {
            // Skip the Neural Engine: this segmentation model has ops the ANE
            // compiler rejects, which makes load throw on a real device (the
            // simulator has no ANE, so it loaded there). GPU is plenty fast.
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndGPU
            let model = try MLModel(contentsOf: url, configuration: config)
            vnModel = try VNCoreMLModel(for: model)
            modelAvailable = true
            loadError = ""
        } catch {
            modelAvailable = false
            loadError = "\(error)"
        }
    }

    func clear() { detections = [] }

    /// Segments a frame off the main actor (throttled) and updates `detections`
    /// with the top classes in the central region. Inference + the pixel scan
    /// run on a background task so the UI render loop and TTS never stall, and a
    /// frame is dropped if one is already in flight.
    func process(_ image: UIImage, minInterval: TimeInterval = 0.5) async {
        guard !isProcessing,
              Date().timeIntervalSince(lastProcess) > minInterval,
              let vnModel, let cg = image.cgImage else { return }
        isProcessing = true
        lastProcess = Date()
        let model = vnModel
        let result = await Task.detached(priority: .userInitiated) {
            ObjectDetector.segment(cg, with: model)
        }.value
        detections = result
        isProcessing = false
    }

    /// Runs Vision inference and the central-box class scan. Nonisolated so the
    /// whole heavy path executes off the main actor.
    nonisolated private static func segment(_ cg: CGImage, with model: VNCoreMLModel) -> [Detection] {
        let request = VNCoreMLRequest(model: model)
        // .scaleFit preserves aspect ratio (letterboxed), so the central-box
        // sampling stays geometrically faithful — .scaleFill would distort it.
        request.imageCropAndScaleOption = .scaleFit
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results as? [VNCoreMLFeatureValueObservation],
              let arr = obs.first?.featureValue.multiArrayValue else { return [] }
        return analyze(arr)
    }

    /// Reads the per-pixel class map and returns the dominant classes in a central box.
    nonisolated private static func analyze(_ arr: MLMultiArray) -> [Detection] {
        let shape = arr.shape.map(\.intValue)
        let strides = arr.strides.map(\.intValue)
        guard shape.count >= 2 else { return [] }
        let h = shape[shape.count - 2], w = shape[shape.count - 1]
        let sh = strides[strides.count - 2], sw = strides[strides.count - 1]
        guard h > 0, w > 0 else { return [] }

        // Central box biased slightly low — "what's roughly in front of you".
        let r0 = Int(Double(h) * 0.35), r1 = Int(Double(h) * 0.78)
        let c0 = Int(Double(w) * 0.30), c1 = Int(Double(w) * 0.70)

        var counts: [Int: Int] = [:]
        var r = r0
        while r < r1 {
            let rowBase = r * sh
            var c = c0
            while c < c1 {
                counts[arr[rowBase + c * sw].intValue, default: 0] += 1
                c += 1
            }
            r += 1
        }

        let total = max(1, (r1 - r0) * (c1 - c0))
        return counts.sorted { $0.value > $1.value }
            .prefix(4)
            .map { Detection(label: name(for: $0.key), confidence: Float($0.value) / Float(total)) }
            .filter { $0.confidence > 0.08 }   // ignore tiny stray regions
    }

    nonisolated private static func name(for index: Int) -> String {
        guard index >= 0, index < ade20k.count else { return "unknown" }
        return ade20k[index]
    }

    /// ADE20K (SceneParse150) class names, 0-indexed.
    nonisolated private static let ade20k: [String] = [
        "wall", "building", "sky", "floor", "tree", "ceiling", "road", "bed", "window", "grass",
        "cabinet", "sidewalk", "person", "ground", "door", "table", "mountain", "plant", "curtain", "chair",
        "car", "water", "painting", "sofa", "shelf", "house", "sea", "mirror", "rug", "field",
        "armchair", "seat", "fence", "desk", "rock", "wardrobe", "lamp", "bathtub", "railing", "cushion",
        "base", "box", "column", "sign", "chest of drawers", "counter", "sand", "sink", "skyscraper", "fireplace",
        "refrigerator", "grandstand", "path", "stairs", "runway", "case", "pool table", "pillow", "screen door", "stairway",
        "river", "bridge", "bookcase", "blind", "coffee table", "toilet", "flower", "book", "hill", "bench",
        "countertop", "stove", "palm tree", "kitchen island", "computer", "swivel chair", "boat", "bar", "arcade machine", "hovel",
        "bus", "towel", "light", "truck", "tower", "chandelier", "awning", "streetlight", "booth", "television",
        "airplane", "dirt track", "clothes", "pole", "land", "bannister", "escalator", "ottoman", "bottle", "buffet",
        "poster", "stage", "van", "ship", "fountain", "conveyer belt", "canopy", "washer", "toy", "swimming pool",
        "stool", "barrel", "basket", "waterfall", "tent", "bag", "motorbike", "cradle", "oven", "ball",
        "food", "step", "tank", "trade name", "microwave", "pot", "animal", "bicycle", "lake", "dishwasher",
        "screen", "blanket", "sculpture", "hood", "sconce", "vase", "traffic light", "tray", "trash can", "fan",
        "pier", "crt screen", "plate", "monitor", "bulletin board", "shower", "radiator", "glass", "clock", "flag",
    ]
}
