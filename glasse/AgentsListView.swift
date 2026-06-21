//
//  AgentsListView.swift
//  glasse
//
//  Lists saved accessibility agents, lets the user switch the active one,
//  delete agents, and create a new one via the chat builder.
//

import SwiftUI

struct AgentsListView: View {
    let store: AgentStore
    let speaker: Speaker
    @Environment(\.dismiss) private var dismiss
    @State private var showBuilder = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.agents) { agent in
                    Button {
                        store.setActive(agent)
                        speaker.speak("Switched to \(agent.name)")
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.name).font(.headline)
                                Text(agent.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if agent.id == store.activeAgent.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("Active")
                            }
                        }
                    }
                    .tint(.primary)
                }
                .onDelete { offsets in
                    offsets.map { store.agents[$0] }.forEach(store.delete)
                }
            }
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { showBuilder = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New agent")
                }
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showBuilder) {
                AgentBuilderView(store: store, speaker: speaker)
            }
        }
    }
}
