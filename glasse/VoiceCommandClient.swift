//
//  VoiceCommandClient.swift
//  glasse
//
//  Turns a spoken command ("describe what's in front of me", "take me to the
//  nearest pharmacy", "switch to my reading assistant", "start captions") into
//  a structured action the app can execute. Uses the Anthropic Messages API
//  with structured outputs, so people with disabilities can drive the whole app
//  by voice, hands-free.
//

import Foundation

/// One voice action the app knows how to perform.
enum VoiceAction: String, Codable, Sendable {
    case describe              // describe what's in front of the user
    case stop                  // stop whatever is running
    case startCaptions         // begin live captions (switches to a captions assistant if needed)
    case identifyObjects       // start on-device object naming
    case stopIdentifyObjects
    case navigate              // walking directions to `destination`
    case switchAssistant       // make `assistantName` active
    case newAssistant          // open the assistant builder
    case showGlassesView       // mirror the glasses camera on the phone
    case hideGlassesView
    case openMonitor           // open the map / monitor screen
    case none                  // unclear / nothing to do
}

/// A parsed voice command: the action, optional parameters, and a short spoken reply.
struct VoiceCommand: Codable, Sendable {
    var action: VoiceAction
    var destination: String?
    var assistantName: String?
    var reply: String
}

/// Snapshot of app state given to the model so it can choose the right action
/// and write an accurate reply.
struct VoiceContext: Sendable {
    var activeAssistant: String
    var activeKind: String          // "vision" or "captions"
    var assistantNames: [String]
    var captionsRunning: Bool
    var describing: Bool
    var identifyingObjects: Bool
    var liveViewOn: Bool
}

struct VoiceCommandClient {
    var model = "claude-opus-4-8"

    func interpret(_ transcript: String, context: VoiceContext) async throws -> VoiceCommand {
        guard Secrets.anthropicAPIKey != "PASTE_YOUR_KEY_HERE",
              !Secrets.anthropicAPIKey.isEmpty else {
            throw VisionError.missingKey
        }

        let system = """
        You are the hands-free voice controller for "Glasses Assist", an accessibility \
        app for blind, low-vision, deaf, and hard-of-hearing users wearing smart camera \
        glasses. The user speaks one command; map it to exactly one action and write a \
        short, warm spoken confirmation in `reply` (one sentence, e.g. "Looking now." or \
        "Heading to the nearest pharmacy.").

        Actions:
        - describe: describe what's in front of the user (their camera/scene).
        - stop: stop whatever is currently running.
        - startCaptions: begin live speech-to-text captions.
        - identifyObjects / stopIdentifyObjects: on-device naming of what's ahead.
        - navigate: walking directions; put the place in `destination`.
        - switchAssistant: set `assistantName` to one of the available assistants (match by meaning).
        - newAssistant: the user wants to create a new assistant.
        - showGlassesView / hideGlassesView: mirror the glasses camera on the phone.
        - openMonitor: open the map that shows the wearer's location and view.
        - none: if the request is unclear or unsupported — in `reply`, briefly say what they can ask.

        Current state:
        - Active assistant: "\(context.activeAssistant)" (\(context.activeKind))
        - Available assistants: \(context.assistantNames.map { "\"\($0)\"" }.joined(separator: ", "))
        - Captions running: \(context.captionsRunning)
        - Describing: \(context.describing); Identifying objects: \(context.identifyingObjects); Live view: \(context.liveViewOn)

        Set `destination` only for navigate, `assistantName` only for switchAssistant; otherwise leave them null.
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "system": system,
            "output_config": ["format": ["type": "json_schema", "schema": Self.schema]],
            "messages": [["role": "user",
                          "content": [["type": "text", "text": transcript]]]],
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Secrets.anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw VisionError.timedOut
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw VisionError.http(status, String(data: data, encoding: .utf8) ?? "")
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
            let cmdData = text.data(using: .utf8)
        else { throw VisionError.noText }

        return try JSONDecoder().decode(VoiceCommand.self, from: cmdData)
    }

    static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "action": ["type": "string",
                       "enum": ["describe", "stop", "startCaptions", "identifyObjects",
                                "stopIdentifyObjects", "navigate", "switchAssistant",
                                "newAssistant", "showGlassesView", "hideGlassesView",
                                "openMonitor", "none"]],
            "destination": ["type": ["string", "null"]],
            "assistantName": ["type": ["string", "null"]],
            "reply": ["type": "string"],
        ],
        "required": ["action", "destination", "assistantName", "reply"],
    ]
}
