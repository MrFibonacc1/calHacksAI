//
//  AgentStore.swift
//  glasse
//
//  Holds the user's saved accessibility agents and the active selection.
//  Agents are stored as local JSON in the app's Documents directory (private,
//  offline, no backend); the active agent id lives in UserDefaults.
//

import Foundation
import Observation

@Observable
@MainActor
final class AgentStore {
    private(set) var agents: [AccessibilityAgent] = []

    var activeAgentID: UUID? {
        didSet {
            UserDefaults.standard.set(activeAgentID?.uuidString, forKey: Self.activeKey)
        }
    }

    /// The active agent, falling back to the first if the stored id is stale.
    var activeAgent: AccessibilityAgent {
        if let id = activeAgentID, let match = agents.first(where: { $0.id == id }) {
            return match
        }
        return agents.first ?? .builtInDefault
    }

    private static let activeKey = "activeAgentID"

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("agents.json")
    }()

    init() {
        load()
        if agents.isEmpty {
            let seed = AccessibilityAgent.builtInDefault
            agents = [seed]
            save()
            activeAgentID = seed.id
        } else if let saved = UserDefaults.standard.string(forKey: Self.activeKey) {
            activeAgentID = UUID(uuidString: saved)
        } else {
            activeAgentID = agents.first?.id
        }
    }

    func add(_ agent: AccessibilityAgent, activate: Bool = true) {
        agents.append(agent)
        save()
        if activate { activeAgentID = agent.id }
    }

    func update(_ agent: AccessibilityAgent) {
        guard let i = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        var updated = agent
        updated.updatedAt = Date()
        agents[i] = updated
        save()
    }

    func delete(_ agent: AccessibilityAgent) {
        agents.removeAll { $0.id == agent.id }
        if agents.isEmpty {
            let seed = AccessibilityAgent.builtInDefault
            agents = [seed]
            activeAgentID = seed.id
        } else if activeAgentID == agent.id {
            activeAgentID = agents.first?.id
        }
        save()
    }

    func setActive(_ agent: AccessibilityAgent) {
        activeAgentID = agent.id
    }

    // MARK: - Persistence

    /// Decodes each agent independently so one malformed entry is skipped rather
    /// than failing the whole array decode (which would silently wipe every saved
    /// agent and reseed the default).
    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? Self.decoder.decode([AccessibilityAgent].self, from: data) {
            agents = decoded
            return
        }
        // Fallback: salvage whatever individual agents still decode.
        if let lenient = try? Self.decoder.decode([Lenient<AccessibilityAgent>].self, from: data) {
            agents = lenient.compactMap(\.value)
        }
    }

    private func save() {
        guard let data = try? Self.encoder.encode(agents) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
