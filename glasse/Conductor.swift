//
//  Conductor.swift
//  glasse
//
//  "Bob" — the Claude conductor. Runs Claude as an agentic tool-use loop: it
//  sends the user's spoken request + a catalog of app capabilities (tools),
//  executes whatever tools Claude calls (via a dispatch closure that maps each
//  tool to an existing app function), feeds the results back, and repeats until
//  Claude is done — then returns its final spoken reply.
//
//  A fast model orchestrates (tool routing is not reasoning-hard); the heavy
//  lifting (vision, agent authoring) happens inside the dispatched tools, which
//  call Opus. No official Swift SDK exists, so this is the same hand-rolled REST
//  plumbing the rest of the app uses, wrapped in a loop.
//

import Foundation

/// One capability Claude can invoke.
struct ConductorTool {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

/// Rolling conversation, kept alive across taps so follow-ups stay in context.
/// A reference type so the loop can append without `inout` across `await`.
@MainActor
final class ConductorHistory {
    var messages: [[String: Any]] = []
    func reset() { messages = [] }
}

struct Conductor {
    /// Fast orchestrator model — tools do the heavy work.
    var model = "claude-haiku-4-5"
    var maxIterations = 3
    let tools: [ConductorTool]

    /// Runs one turn. `history` is the rolling conversation the caller keeps
    /// alive across taps (so follow-ups stay in context). `dispatch(name,input)`
    /// executes a tool and returns a short result string. Returns Claude's final
    /// reply text.
    @MainActor
    func run(transcript: String,
             system: String,
             history: ConductorHistory,
             dispatch: (String, [String: Any]) async -> String) async throws -> String {
        guard Secrets.anthropicAPIKey != "PASTE_YOUR_KEY_HERE",
              !Secrets.anthropicAPIKey.isEmpty else { throw VisionError.missingKey }

        let toolDefs = tools.map { t -> [String: Any] in
            ["name": t.name, "description": t.description, "input_schema": t.inputSchema]
        }
        history.messages.append(["role": "user", "content": [["type": "text", "text": transcript]]])

        var finalText = ""
        for _ in 0..<maxIterations {
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 1024,
                "system": system,
                "tools": toolDefs,
                "messages": history.messages,
            ]
            let json = try await post(body)
            let content = json["content"] as? [[String: Any]] ?? []

            var assistantText = ""
            var toolUses: [[String: Any]] = []
            for block in content {
                switch block["type"] as? String {
                case "text": assistantText += (block["text"] as? String ?? "")
                case "tool_use": toolUses.append(block)
                default: break
                }
            }
            if !assistantText.isEmpty { finalText = assistantText }
            history.messages.append(["role": "assistant", "content": content])

            let stop = json["stop_reason"] as? String
            if toolUses.isEmpty || stop == "end_turn" { break }

            // Execute each tool; a failing tool returns an error string but never
            // kills the loop.
            var results: [[String: Any]] = []
            for tu in toolUses {
                let name = tu["name"] as? String ?? ""
                let input = tu["input"] as? [String: Any] ?? [:]
                let id = tu["id"] as? String ?? ""
                let result = await dispatch(name, input)
                results.append(["type": "tool_result", "tool_use_id": id, "content": result])
            }
            history.messages.append(["role": "user", "content": results])
        }
        return finalText
    }

    /// POST with one retry on rate-limit / overload (no SDK = no auto-backoff).
    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Secrets.anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        for attempt in 0..<2 {
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let error as URLError where error.code == .timedOut {
                throw VisionError.timedOut
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            if (status == 429 || status == 529) && attempt == 0 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                continue
            }
            throw VisionError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        throw VisionError.http(0, "retry exhausted")
    }
}
