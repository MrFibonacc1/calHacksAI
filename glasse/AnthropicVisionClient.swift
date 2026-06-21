//
//  AnthropicVisionClient.swift
//  glasse
//
//  Calls the Anthropic Messages API to describe / answer questions about an
//  image. Swift has no official Anthropic SDK, so this uses the REST API
//  directly.
//
//  NOTE: Embedding the API key in the app is fine for development. For a
//  shipped app, route this call through a backend (AWS / GCP / Azure) so the
//  key isn't extractable from the binary.
//

import Foundation

enum VisionError: Error {
    case missingKey
    case badImage
    case http(Int, String)
    case noText
    case timedOut
}

/// One message in a vision conversation. Attach an image to a user turn to give
/// Claude something to look at; follow-up turns can be text-only so context
/// (e.g. "the left one") stays grounded against earlier turns and pixels.
struct VisionMessage {
    enum Role: String { case user, assistant }
    let role: Role
    let text: String
    var imageJPEG: Data? = nil
}

struct AnthropicVisionClient {
    /// Most capable model. For lower latency/cost on follow-ups you could switch
    /// to "claude-haiku-4-5" or "claude-sonnet-4-6".
    var model = "claude-opus-4-8"

    /// One-shot scene description, shaped by the active accessibility agent.
    func describe(imageData jpeg: Data, agent: AccessibilityAgent) async throws -> String {
        try await converse(
            messages: [VisionMessage(role: .user, text: "Describe what is in front of me.", imageJPEG: jpeg)],
            system: agent.systemPrompt,
            maxTokens: agent.verbosity.maxTokens)
    }

    /// Ask a custom question about the current frame, optionally continuing a
    /// prior conversation (multi-turn vision). Pass `history` to keep the thread
    /// grounded; attach `imageData` when there's a fresh frame to look at.
    func ask(_ question: String,
             imageData jpeg: Data?,
             agent: AccessibilityAgent,
             history: [VisionMessage] = []) async throws -> String {
        var messages = history
        messages.append(VisionMessage(role: .user, text: question, imageJPEG: jpeg))
        return try await converse(messages: messages,
                                  system: agent.systemPrompt,
                                  maxTokens: agent.verbosity.maxTokens)
    }

    /// General multimodal call: send a full message list (any user turn may
    /// carry an image) and return Claude's reply text. Shared primitive for
    /// describe, conversational vision, and the conductor.
    func converse(messages: [VisionMessage], system: String, maxTokens: Int, modelOverride: String? = nil) async throws -> String {
        guard Secrets.anthropicAPIKey != "PASTE_YOUR_KEY_HERE",
              !Secrets.anthropicAPIKey.isEmpty else {
            throw VisionError.missingKey
        }
        let model = modelOverride ?? self.model   // callers can request a faster model (e.g. explore mode)

        let span = Telemetry.startSpan("vision.converse", op: "http.client")
        defer { span.finish() }

        let apiMessages: [[String: Any]] = messages.map { m in
            var content: [[String: Any]] = []
            if let jpeg = m.imageJPEG {
                content.append([
                    "type": "image",
                    "source": ["type": "base64",
                               "media_type": "image/jpeg",
                               "data": jpeg.base64EncodedString()],
                ])
            }
            content.append(["type": "text", "text": m.text])
            return ["role": m.role.rawValue, "content": content]
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": apiMessages,
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Secrets.anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30   // don't let a blind user wait forever

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            Telemetry.capture(VisionError.timedOut, ["endpoint": "anthropic.messages", "model": model])
            throw VisionError.timedOut
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            Telemetry.capture(VisionError.http(status, ""), ["endpoint": "anthropic.messages", "status": status])
            throw VisionError.http(status, String(data: data, encoding: .utf8) ?? "")
        }

        // Response shape: { "content": [ { "type": "text", "text": "..." }, ... ] }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else { throw VisionError.noText }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
