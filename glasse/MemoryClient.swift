//
//  MemoryClient.swift
//  glasse
//
//  Talks to the glasse memory-service (see /memory-service) to give Bob per-user,
//  cross-session memory backed by Redis vector search. The app never holds Redis or
//  Anthropic creds — it calls this backend, which holds them.
//
//  Wiring (two calls per conductor turn):
//    1. BEFORE the Claude call — `recall(query:)` and fold the returned lines into
//       conductorSystemPrompt() as "What I've learned about this user".
//    2. AFTER the reply — `learn(userText:assistantText:)` so durable preferences
//       are extracted + stored for next time.
//
//  Safe by default: with no `baseURL` configured it's a no-op (returns []), so the
//  app keeps working until the backend is deployed.
//

import Foundation

@MainActor
final class MemoryClient {
    /// Backend base URL. DEV: the Mac running the memory-service via docker, on the
    /// same Wi-Fi as the iPhone (this IP is from DHCP — update it if it changes, or
    /// swap for a deployed https URL for a demo/prod). Empty string = disabled (no-op).
    static let baseURL = "http://10.2.38.90:8080"

    /// Stable per-user id. Replace with your real auth/user id; falls back to a
    /// per-install id so memory is at least consistent on one device.
    static var ownerID: String {
        if let id = UserDefaults.standard.string(forKey: "glasse.ownerID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "glasse.ownerID")
        return id
    }

    private var enabled: Bool { !Self.baseURL.isEmpty }

    /// Memories most relevant to `query` for this user (call before Claude).
    func recall(query: String, limit: Int = 5) async -> [String] {
        guard enabled,
              let data = try? await post("/memory/search",
                                         ["owner_id": Self.ownerID, "query": query, "limit": limit]),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mems = obj["memories"] as? [[String: Any]]
        else { return [] }
        return mems.compactMap { $0["text"] as? String }
    }

    /// Extract + store durable preferences from a turn (fire-and-forget after the reply).
    func learn(userText: String, assistantText: String) {
        guard enabled else { return }
        Task { _ = try? await post("/memory/learn",
                                   ["owner_id": Self.ownerID,
                                    "user_text": userText,
                                    "assistant_text": assistantText]) }
    }

    /// Store one explicit memory ("remember that I…").
    func remember(_ text: String, type: String = "preference") {
        guard enabled else { return }
        Task { _ = try? await post("/memory/remember",
                                   ["owner_id": Self.ownerID, "text": text, "type": type]) }
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: URL(string: Self.baseURL + path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 5   // memory is an enhancement — never block the turn for long
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }
}
