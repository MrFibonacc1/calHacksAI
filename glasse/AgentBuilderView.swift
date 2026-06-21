//
//  AgentBuilderView.swift
//  glasse
//
//  Chat screen where the user describes their accessibility needs and Claude
//  builds a custom agent. On finalize, the agent is saved and made active.
//

import SwiftUI

struct AgentBuilderView: View {
    let store: AgentStore
    let speaker: Speaker
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [ChatMessage] = [
        ChatMessage(role: .assistant, text:
            "Tell me what you need from your glasses and I'll build an assistant for you. " +
            "For example: \"I'm blind — give me short, safe-to-walk guidance and read signs aloud.\"")
    ]
    @State private var input = ""
    @State private var isThinking = false
    @State private var pendingDraft: AgentDraft?

    private let builder = AgentBuilderClient()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { bubble($0) }
                            if isThinking {
                                ProgressView().padding(.leading, 4).id("thinking")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                if let draft = pendingDraft {
                    draftCard(draft)
                }

                HStack(spacing: 8) {
                    TextField("Describe your needs…", text: $input, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isThinking)
                    Button { Task { await send() } } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                    }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || isThinking)
                }
                .padding()
            }
            .navigationTitle("New Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    @ViewBuilder private func bubble(_ m: ChatMessage) -> some View {
        HStack {
            if m.role == .user { Spacer(minLength: 40) }
            Text(m.text)
                .padding(10)
                .background(m.role == .user ? Theme.userBubble : Theme.assistantBubble)
                .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleCorner))
            if m.role == .assistant { Spacer(minLength: 40) }
        }
        .id(m.id)
    }

    @ViewBuilder private func draftCard(_ draft: AgentDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.name).font(.headline)
            Text(draft.summary).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button("Save agent") {
                    store.add(draft.makeAgent())
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                Button("Keep editing") { pendingDraft = nil }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Theme.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner))
        .padding(.horizontal)
    }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        pendingDraft = nil
        messages.append(ChatMessage(role: .user, text: text))
        isThinking = true
        defer { isThinking = false }

        // The API requires the first message to be from the user; drop the
        // UI-only assistant greeting before sending.
        let history = Array(messages.drop(while: { $0.role == .assistant }))
        do {
            let turn = try await builder.nextTurn(history: history)
            if turn.done, let draft = turn.agent {
                let confirm = "Created \"\(draft.name)\" — \(draft.summary)"
                messages.append(ChatMessage(role: .assistant, text: confirm))
                speaker.speak(confirm)
                pendingDraft = draft
            } else if let question = turn.question {
                messages.append(ChatMessage(role: .assistant, text: question))
                speaker.speak(question)
            } else {
                messages.append(ChatMessage(role: .assistant, text: "Let's try describing that a different way."))
            }
        } catch {
            messages.append(ChatMessage(role: .assistant, text: "Sorry — \(error.localizedDescription)"))
        }
    }
}
