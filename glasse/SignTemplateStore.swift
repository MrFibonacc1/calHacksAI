//
//  SignTemplateStore.swift
//  glasse
//
//  Persists the user-recorded sign templates (one motion template per vocabulary
//  word) as JSON in the app's Documents directory, so signs taught in "teach mode"
//  survive relaunches. Mirrors AgentStore's local-JSON persistence.
//

import Foundation
import Observation

@Observable
@MainActor
final class SignTemplateStore {
    private(set) var templates: [SignTemplate] = []

    @ObservationIgnored private let url: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("sign_templates.json")
    }()

    init() { load() }

    /// Labels that currently have a recorded template (for the teach-mode checklist).
    var taughtLabels: Set<String> { Set(templates.map { $0.label.uppercased() }) }
    var count: Int { templates.count }

    /// Save (or replace) the template for a word — latest recording wins.
    func save(_ template: SignTemplate) {
        let key = template.label.uppercased()
        templates.removeAll { $0.label.uppercased() == key }
        templates.append(template)
        persist()
    }

    func remove(_ label: String) {
        let key = label.uppercased()
        templates.removeAll { $0.label.uppercased() == key }
        persist()
    }

    func removeAll() {
        templates.removeAll()
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SignTemplate].self, from: data) else { return }
        templates = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
