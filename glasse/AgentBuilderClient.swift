//
//  AgentBuilderClient.swift
//  glasse
//
//  Turns a chat conversation about a person's accessibility needs into a
//  structured AccessibilityAgent, using the Anthropic Messages API with
//  structured outputs (output_config.format + a JSON schema).
//
//  Each call returns a BuilderTurn: either a clarifying question, or a final
//  agent draft when Claude has enough to finalize.
//

import Foundation

/// The Claude-controlled fields of an agent (the device fills in id/dates).
struct AgentDraft: Codable, Sendable {
    var name: String
    var summary: String
    var kind: AgentKind
    var outputMode: OutputMode
    var instructions: String
    var verbosity: Verbosity
    var captureMode: CaptureMode
    var periodSeconds: Int
    var enabledNodeIDs: [String]

    /// Materializes a full agent with device-owned fields.
    func makeAgent() -> AccessibilityAgent {
        AccessibilityAgent(
            name: name,
            summary: summary,
            kind: kind,
            outputMode: outputMode,   // init enforces captions ⇒ non-speech
            instructions: instructions,
            verbosity: verbosity,
            captureMode: captureMode,
            periodSeconds: periodSeconds,   // AccessibilityAgent.init clamps to 3...30
            enabledNodeIDs: enabledNodeIDs)
    }
}

/// One structured-output turn from the builder.
struct BuilderTurn: Codable, Sendable {
    var done: Bool
    var question: String?   // present when done == false
    var agent: AgentDraft?  // present when done == true
}

/// A message in the builder conversation.
struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

enum BuilderError: LocalizedError {
    case missingKey
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: return "No API key set. Add it in Secrets.swift."
        case .http(let code, _): return "The builder request failed (HTTP \(code))."
        case .badResponse: return "The builder returned something unexpected. Try rephrasing."
        }
    }
}

struct AgentBuilderClient {
    var model = "claude-opus-4-8"

    /// Sends the running conversation and returns the next turn.
    func nextTurn(history: [ChatMessage]) async throws -> BuilderTurn {
        guard Secrets.anthropicAPIKey != "PASTE_YOUR_KEY_HERE",
              !Secrets.anthropicAPIKey.isEmpty else {
            throw BuilderError.missingKey
        }

        let system = """
        You help a person with a disability create a custom "accessibility agent" \
        for smart camera glasses. From the user's description, infer the right configuration. \
        Ask at most one or two short clarifying questions ONLY if essential; otherwise finalize.

        Choose `kind`:
        - "vision" for blind or low-vision users — the glasses camera describes what's in front of them.
        - "captions" for deaf or hard-of-hearing users — the microphone transcribes nearby speech to live text.

        Choose `outputMode`:
        - "speech" (spoken aloud) — best for blind users.
        - "screen" (large text on the phone) — best for deaf or low-vision users.
        - "glassesDisplay" (text on the in-lens display) — only if the user specifically wants on-lens text.

        Pick `enabledNodeIDs` — the capabilities this assistant should have — using ids from this catalog:
        \(NodeCatalog.catalogText())

        For a "vision" agent, write `instructions` in the second person to the vision model \
        (e.g. "You are the eyes for..."); include "describe_scene" plus any of "safe_to_walk", "read_text", \
        "navigation", "identify_objects" that fit the user's needs; set `verbosity` (brief/normal/detailed) \
        and `captureMode` (onDemand, or periodic with periodSeconds 3–30 for continuous "is it safe to walk").
        For a "captions" agent, include "captions" (and "sign_reading" or "sound_alerts" only if clearly relevant) \
        and use onDemand.

        Keep `name` under four words and `summary` to one sentence. Set `done` true only when finalizing \
        (include `agent`); otherwise set `done` false and include `question`.
        """

        let messages: [[String: Any]] = history.map { m in
            ["role": m.role == .user ? "user" : "assistant",
             "content": [["type": "text", "text": m.text]]]
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "thinking": ["type": "adaptive"],
            "system": system,
            "output_config": ["format": ["type": "json_schema", "schema": Self.schema]],
            "messages": messages,
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Secrets.anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw BuilderError.http(status, String(data: data, encoding: .utf8) ?? "")
        }

        // Structured output still arrives as a JSON string inside content[].text.
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
            let turnData = text.data(using: .utf8)
        else { throw BuilderError.badResponse }

        do {
            return try JSONDecoder().decode(BuilderTurn.self, from: turnData)
        } catch {
            throw BuilderError.badResponse
        }
    }

    // MARK: - Structured-output schema
    //
    // Constraints: every object needs additionalProperties:false and lists all
    // keys in `required`; enums for fixed value sets; no min/max/length bounds
    // (enforced via prompt + on-device clamp); nullable fields use ["type", "null"].

    static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "done": ["type": "boolean"],
            "question": ["type": ["string", "null"]],
            "agent": [
                "type": ["object", "null"],
                "additionalProperties": false,
                "properties": [
                    "name": ["type": "string"],
                    "summary": ["type": "string"],
                    "kind": ["type": "string", "enum": ["vision", "captions"]],
                    "outputMode": ["type": "string", "enum": ["speech", "screen", "glassesDisplay"]],
                    "instructions": ["type": "string"],
                    "verbosity": ["type": "string", "enum": ["brief", "normal", "detailed"]],
                    "captureMode": ["type": "string", "enum": ["onDemand", "periodic"]],
                    "periodSeconds": ["type": "integer"],
                    "enabledNodeIDs": ["type": "array", "items": ["type": "string", "enum": NodeCatalog.ids]],
                ],
                "required": ["name", "summary", "kind", "outputMode", "instructions", "verbosity", "captureMode", "periodSeconds", "enabledNodeIDs"],
            ],
        ],
        "required": ["done", "question", "agent"],
    ]
}
