//
//  AccessibilityAgent.swift
//  glasse
//
//  A saved, user-defined "accessibility agent": a config that governs how the
//  glasses behave. Created by the chat builder, switched from the phone.
//

import Foundation

/// What the agent fundamentally does.
enum AgentKind: String, Codable, CaseIterable, Sendable {
    case vision     // camera → describe (blind / low-vision)
    case captions   // microphone → live speech-to-text (deaf / hard-of-hearing)
}

/// Where the agent's output goes.
enum OutputMode: String, Codable, CaseIterable, Sendable {
    case speech         // spoken aloud (default; routes to glasses speaker)
    case screen         // large text on the phone screen
    case glassesDisplay // text on the in-lens display (needs real Display hardware)
}

enum Verbosity: String, Codable, CaseIterable, Sendable {
    case brief, normal, detailed

    var maxTokens: Int {
        switch self {
        case .brief: return 150
        case .normal: return 400
        case .detailed: return 700
        }
    }
    var lengthGuidance: String {
        switch self {
        case .brief: return "Respond in one short sentence."
        case .normal: return "Respond in 1 to 3 short sentences."
        case .detailed: return "Respond in up to 5 short sentences."
        }
    }
}

enum CaptureMode: String, Codable, CaseIterable, Sendable {
    case onDemand, periodic
}

struct AgentFeatures: Codable, Equatable, Sendable {
    var sceneDescription: Bool
    var safeToWalk: Bool
    var navigation: Bool
    var textReading: Bool

    static let `default` = AgentFeatures(
        sceneDescription: true, safeToWalk: false, navigation: false, textReading: false)

    var promptDirectives: [String] {
        var lines: [String] = []
        if safeToWalk {
            lines.append("Say whether it appears safe to walk forward and roughly how far the path is clear; call out steps, trip hazards, and obstacles.")
        }
        if navigation {
            lines.append("Describe the layout and where key things are relative to the user (left, right, ahead) to help them move.")
        }
        if textReading {
            lines.append("Read aloud any important signs, labels, or printed text you can see.")
        }
        return lines
    }
}

struct AccessibilityAgent: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var summary: String
    var kind: AgentKind
    var outputMode: OutputMode
    var instructions: String
    var verbosity: Verbosity
    var captureMode: CaptureMode
    var periodSeconds: Int
    var enabledNodeIDs: [String]   // capabilities, referencing NodeCatalog (was: features)
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         summary: String,
         kind: AgentKind = .vision,
         outputMode: OutputMode = .speech,
         instructions: String = "",
         verbosity: Verbosity = .normal,
         captureMode: CaptureMode = .onDemand,
         periodSeconds: Int = 8,
         enabledNodeIDs: [String] = ["describe_scene"],
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.summary = summary
        self.kind = kind
        self.outputMode = Self.coercedOutputMode(outputMode, for: kind)
        self.instructions = instructions
        self.verbosity = verbosity
        self.captureMode = captureMode
        self.periodSeconds = max(3, min(30, periodSeconds))
        self.enabledNodeIDs = enabledNodeIDs.isEmpty ? NodeCatalog.defaults(for: kind) : enabledNodeIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Modality safety: a deaf / hard-of-hearing (captions) user must never get a
    /// speech-only assistant — fall back to on-screen / in-lens text. Applied by
    /// BOTH the designated init and the Codable decoder so the invariant can't drift.
    static func coercedOutputMode(_ mode: OutputMode, for kind: AgentKind) -> OutputMode {
        (kind == .captions && mode == .speech) ? .screen : mode
    }

    /// Maps a legacy AgentFeatures bool-set (older saved agents) to node IDs.
    /// Captions agents never used the vision feature flags, so they migrate to the
    /// captions default rather than a vision node.
    static func nodeIDs(from f: AgentFeatures, kind: AgentKind) -> [String] {
        guard kind == .vision else { return NodeCatalog.defaults(for: kind) }
        var ids = ["describe_scene"]
        if f.safeToWalk { ids.append("safe_to_walk") }
        if f.navigation { ids.append("navigation") }
        if f.textReading { ids.append("read_text") }
        return ids
    }

    private enum LegacyKeys: String, CodingKey { case features }

    /// Tolerant decoder so agents saved by older builds (without the newer
    /// fields) still load with sensible defaults instead of being wiped. Legacy
    /// agents stored `features` booleans — migrate them to `enabledNodeIDs`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decode(String.self, forKey: .summary)
        kind = try c.decodeIfPresent(AgentKind.self, forKey: .kind) ?? .vision
        outputMode = Self.coercedOutputMode(
            try c.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? .speech, for: kind)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        verbosity = try c.decodeIfPresent(Verbosity.self, forKey: .verbosity) ?? .normal
        captureMode = try c.decodeIfPresent(CaptureMode.self, forKey: .captureMode) ?? .onDemand
        periodSeconds = try c.decodeIfPresent(Int.self, forKey: .periodSeconds) ?? 8
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()

        if let ids = try c.decodeIfPresent([String].self, forKey: .enabledNodeIDs), !ids.isEmpty {
            enabledNodeIDs = ids
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
                  let f = try? legacy.decode(AgentFeatures.self, forKey: .features) {
            enabledNodeIDs = AccessibilityAgent.nodeIDs(from: f, kind: kind)   // migrate old bool-set
        } else {
            enabledNodeIDs = NodeCatalog.defaults(for: kind)
        }
    }

    /// Full system prompt for a vision agent: generated instructions + capability/verbosity directives.
    var systemPrompt: String {
        var parts = [instructions]
        parts.append(contentsOf: NodeCatalog.directives(for: enabledNodeIDs))
        parts.append(verbosity.lengthGuidance)
        return parts.joined(separator: " ")
    }

    static let builtInDefault = AccessibilityAgent(
        name: "General Assistant",
        summary: "Describes what's in front of you in a sentence or two.",
        kind: .vision,
        outputMode: .speech,
        instructions: """
        You are the eyes for a person who is blind, wearing camera glasses. \
        Describe what is in front of them clearly and concisely. \
        Lead with the most important things: obstacles, people, hazards, and any readable text. \
        Be direct and factual. Do not begin with phrases like "This image shows" — \
        speak the scene as if you are looking on their behalf.
        """,
        verbosity: .normal,
        enabledNodeIDs: ["describe_scene"])
}
