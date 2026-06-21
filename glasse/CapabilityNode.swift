//
//  CapabilityNode.swift
//  glasse
//
//  A capability "node" is one thing an accessibility assistant can do — describe
//  a scene, read text, caption speech, navigate, and so on. The catalog is the
//  SINGLE source of truth for the set of capabilities, and it's projected into:
//
//    • the structured-output schema enum Claude picks from when building an agent
//      (one generated list instead of the old duplicated `features` objects), and
//    • the per-agent prompt directives folded into `AccessibilityAgent.systemPrompt`,
//    • the chips shown on screen so you can SEE what Claude composed.
//
//  An agent's capabilities are just `enabledNodeIDs: [String]` referencing these.
//  (The live voice "conductor" keeps its own always-available tool set — nodes
//  describe what an *agent* is made of, not what Bob is allowed to call.)
//

import SwiftUI

struct CapabilityNode: Identifiable {
    let id: String          // stable; also the value Claude emits in enabledNodeIDs
    let title: String       // chip label
    let blurb: String       // shown to Claude in the catalog + as the chip's meaning
    let symbol: String      // SF Symbol for the chip
    let tint: Color
    let directive: String?  // folded into the agent's system prompt when enabled
    let kind: AgentKind?    // affinity hint (vision / captions); nil = either
    let experimental: Bool

    init(id: String, title: String, blurb: String, symbol: String, tint: Color,
         directive: String? = nil, kind: AgentKind? = nil, experimental: Bool = false) {
        self.id = id; self.title = title; self.blurb = blurb; self.symbol = symbol
        self.tint = tint; self.directive = directive; self.kind = kind; self.experimental = experimental
    }
}

enum NodeCatalog {
    static let all: [CapabilityNode] = [
        CapabilityNode(
            id: "describe_scene", title: "Describe scene",
            blurb: "Describe what's in front of the user, leading with obstacles, people, hazards, and readable text.",
            symbol: "eye.fill", tint: .indigo,
            directive: "Describe what is in front of them, leading with obstacles, people, hazards, and any readable text.",
            kind: .vision),
        CapabilityNode(
            id: "safe_to_walk", title: "Safe to walk",
            blurb: "Say whether the path ahead is clear and how far, calling out steps and trip hazards.",
            symbol: "figure.walk", tint: .green,
            directive: "Say whether it appears safe to walk forward and roughly how far the path is clear; call out steps, trip hazards, and obstacles.",
            kind: .vision),
        CapabilityNode(
            id: "read_text", title: "Read text",
            blurb: "Read aloud signs, labels, menus, and mail the camera sees.",
            symbol: "text.viewfinder", tint: .orange,
            directive: "Read aloud any important signs, labels, or printed text you can see.",
            kind: .vision),
        CapabilityNode(
            id: "navigation", title: "Navigation",
            blurb: "Describe the layout and where things are relative to the user, to help them move.",
            symbol: "location.fill", tint: .blue,
            directive: "Describe the layout and where key things are relative to the user (left, right, ahead) to help them move.",
            kind: .vision),
        CapabilityNode(
            id: "identify_objects", title: "Identify objects",
            blurb: "Name the main object directly ahead, briefly and on-device.",
            symbol: "viewfinder", tint: .teal,
            directive: "When useful, name the main object directly ahead in a word or two.",
            kind: .vision),
        CapabilityNode(
            id: "captions", title: "Live captions",
            blurb: "Transcribe nearby speech into live on-screen / in-lens captions.",
            symbol: "captions.bubble.fill", tint: .purple,
            directive: nil, kind: .captions),
        CapabilityNode(
            id: "sign_reading", title: "Sign reading",
            blurb: "Read a signer's fingerspelling into captions on the lens (experimental, best-effort, on-device).",
            symbol: "hand.raised.fill", tint: .pink,
            directive: nil, kind: .captions, experimental: true),
        CapabilityNode(
            id: "sign_speaking", title: "Sign what I say",
            blurb: "Show the wearer how to fingerspell what they just said, so they can sign it back to a Deaf person (experimental, on-device; the spelling alphabet, not fluent ASL).",
            symbol: "hand.raised.fingers.spread.fill", tint: .mint,
            directive: nil, kind: .captions, experimental: true),
        CapabilityNode(
            id: "sign_recognition", title: "Read signs",
            blurb: "Recognize a small taught set of whole-word signs from the camera into captions (experimental, on-device, single-signer template matching).",
            symbol: "hands.and.sparkles.fill", tint: .teal,
            directive: nil, kind: .captions, experimental: true),
        CapabilityNode(
            id: "sound_alerts", title: "Sound alerts",
            blurb: "Alert the user to important sounds — alarms, doorbells, or their name.",
            symbol: "bell.fill", tint: .red,
            directive: nil, kind: .captions, experimental: true),
    ]

    static subscript(_ id: String) -> CapabilityNode? { all.first { $0.id == id } }

    /// Every valid node id — feeds the structured-output enum (one source).
    static var ids: [String] { all.map(\.id) }

    /// The prompt directives for an agent's enabled nodes, in catalog order.
    static func directives(for ids: [String]) -> [String] {
        all.filter { ids.contains($0.id) }.compactMap(\.directive)
    }

    /// The nodes for an agent's enabled ids, in catalog order (for the chips UI).
    static func chips(for ids: [String]) -> [CapabilityNode] {
        all.filter { ids.contains($0.id) }
    }

    /// Sensible default capability for a fresh agent of the given kind.
    static func defaults(for kind: AgentKind) -> [String] {
        kind == .captions ? ["captions"] : ["describe_scene"]
    }

    /// "- id: blurb" lines injected into the builder + conductor prompts so Claude
    /// knows what each id means when it picks enabledNodeIDs.
    static func catalogText() -> String {
        all.map { "- \($0.id): \($0.blurb)\($0.experimental ? " (experimental)" : "")" }
            .joined(separator: "\n")
    }
}
