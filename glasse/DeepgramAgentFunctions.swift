//
//  DeepgramAgentFunctions.swift
//  glasse
//
//  Bridges the Deepgram Voice Agent's CLIENT-SIDE function calls to glasse's actions.
//  When the agent decides to call a function, Deepgram sends a `FunctionCallRequest`
//  over the agent websocket; we run it (reusing the conductor's `dispatchTool`, and
//  the Redis memory-service via MemoryClient) and send back a `FunctionCallResponse`.
//
//  Wiring (in your Deepgram agent websocket receive loop):
//      let funcs = DeepgramAgentFunctions(memory: memory)
//      funcs.dispatch = { name, input in await dispatchTool(name, input) }   // from ContentView
//      // on each incoming text message `data`:
//      for response in await funcs.handle(data) { socket.send(.data(response)) }
//
//  Message format per Deepgram's Voice Agent docs (June 2026):
//    in:  {"type":"FunctionCallRequest","functions":[{"id","name","arguments","client_side"}]}
//    out: {"type":"FunctionCallResponse","id","name","content"}
//  NOTE: some older Deepgram examples use "function_call_id"/"output" instead of
//  "id"/"content" — if your API version rejects these, switch to those keys.
//

import Foundation

@MainActor
final class DeepgramAgentFunctions {
    /// Runs a glasse DEVICE action through the conductor's existing tool dispatch.
    /// Set this from ContentView: `funcs.dispatch = { name, input in await dispatchTool(name, input) }`.
    var dispatch: ((String, [String: Any]) async -> String)?

    /// Per-user Redis memory (remember / recall) via the memory-service.
    private let memory: MemoryClient

    init(memory: MemoryClient) { self.memory = memory }

    /// Decode a raw agent websocket message; if it's a FunctionCallRequest, run each
    /// client-side function and return the FunctionCallResponse message(s) to send
    /// back. Returns [] for any other message type.
    func handle(_ data: Data) async -> [Data] {
        guard let req = try? JSONDecoder().decode(FunctionCallRequest.self, from: data),
              req.type == "FunctionCallRequest" else { return [] }
        var out: [Data] = []
        for call in req.functions where call.client_side != false {   // handle client-side (and unspecified)
            let content = await run(name: call.name, argsJSON: call.arguments)
            if let d = try? JSONEncoder().encode(FunctionCallResponse(id: call.id, name: call.name, content: content)) {
                out.append(d)
            }
        }
        return out
    }

    /// Map one function name + JSON arguments to a glasse action; return the text the
    /// agent will speak/show.
    private func run(name: String, argsJSON: String) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        switch name {
        case "describe_scene":
            var input: [String: Any] = [:]
            if let q = args["question"] as? String, !q.isEmpty {
                input["question"] = q
            } else if (args["detail"] as? String) == "detailed" {
                input["question"] = "Describe in detail what's in front of me."
            }
            return await device("describe_scene", input, fallback: "I can't see anything right now.")
        case "read_text":
            var input: [String: Any] = [:]
            if let q = args["question"] as? String, !q.isEmpty { input["question"] = q }
            return await device("read_text", input, fallback: "I couldn't read any text.")
        case "identify_objects":
            let stop = (args["action"] as? String) == "stop"
            return await device(stop ? "stop_identify_objects" : "identify_objects", [:], fallback: "Done.")
        case "start_captions":
            return await device("start_captions", [:], fallback: "Live captions started.")
        case "read_fingerspelling":
            return await device("read_fingerspelling", [:], fallback: "Opened the fingerspelling reader.")
        case "navigate":
            let dest = (args["destination"] as? String) ?? ""
            guard !dest.isEmpty else { return "Where would you like to go?" }
            return await device("navigate", ["destination": dest], fallback: "I couldn't find a route.")
        case "call_for_help":
            return await device("call_for_help", [:], fallback: "Calling for help now.")
        case "set_text_to_speech":
            let on = (args["on"] as? Bool) ?? true
            return await device("change_setting", ["setting": "speech", "on": on],
                                fallback: on ? "Turned text to speech on." : "Turned text to speech off.")
        case "remember_preference":
            let text = (args["text"] as? String) ?? ""
            guard !text.isEmpty else { return "There was nothing to remember." }
            memory.remember(text, type: (args["type"] as? String) ?? "preference")
            return "Got it — I'll remember that."
        case "recall_preferences":
            let mems = await memory.recall(query: (args["query"] as? String) ?? "")
            return mems.isEmpty ? "I don't have anything saved about that yet." : mems.joined(separator: "; ")
        default:
            return "I don't know how to do that."
        }
    }

    private func device(_ name: String, _ input: [String: Any], fallback: String) async -> String {
        guard let dispatch else { return fallback }
        let result = await dispatch(name, input)
        return result.isEmpty ? fallback : result
    }

    // MARK: - Wire format

    private struct FunctionCallRequest: Decodable {
        let type: String
        let functions: [Call]
        struct Call: Decodable {
            let id: String
            let name: String
            let arguments: String       // JSON string of the args
            let client_side: Bool?
        }
    }

    private struct FunctionCallResponse: Encodable {
        let type = "FunctionCallResponse"
        let id: String
        let name: String
        let content: String
    }
}
