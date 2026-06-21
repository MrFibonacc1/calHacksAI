//
//  MemoryStore.swift
//  glasse
//
//  The conductor's compounding memory: things it should remember about the user
//  and their world (disability + preferences, named people/pets/objects with
//  visual cues, places, routines, meds). Stored as local JSON in Documents —
//  strictly on-device, no backend (same pattern as AgentStore). Injected into
//  the system prompt each turn so "a dog" can become "Scout is at the door."
//

import Foundation
import Observation

struct MemoryNote: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var category: String   // person | object | place | med | preference | routine | fact
    var text: String
    var createdAt: Date = Date()
}

@Observable
@MainActor
final class MemoryStore {
    private(set) var notes: [MemoryNote] = []

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("memory.json")
    }()

    init() { load() }

    func remember(category: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notes.append(MemoryNote(category: category.isEmpty ? "fact" : category, text: trimmed))
        if notes.count > 200 { notes.removeFirst(notes.count - 200) }   // bound it
        save()
    }

    /// Simple substring recall; returns matching notes (or recent ones if blank).
    func recall(matching query: String) -> [MemoryNote] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Array(notes.suffix(20)) }
        return notes.filter { $0.text.lowercased().contains(q) || $0.category.lowercased().contains(q) }
    }

    func forgetAll() {
        notes = []
        save()
    }

    /// Everything the conductor knows, formatted for the system prompt.
    var promptBlock: String {
        guard !notes.isEmpty else { return "(nothing remembered yet)" }
        return notes.map { "- [\($0.category)] \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? Self.decoder.decode([MemoryNote].self, from: data) else { return }
        notes = decoded
    }

    private func save() {
        guard let data = try? Self.encoder.encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
