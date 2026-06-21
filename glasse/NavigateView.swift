//
//  NavigateView.swift
//  glasse
//
//  Enter a destination and get a walking route read aloud, step by step.
//

import SwiftUI

struct NavigateView: View {
    let nav: NavigationManager
    let speaker: Speaker
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack {
                    TextField("Where to? (e.g. Starbucks)", text: $destination)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.go)
                        .onSubmit(go)
                    Button("Go", action: go)
                        .disabled(destination.trimmingCharacters(in: .whitespaces).isEmpty || nav.isBusy)
                }

                if nav.isBusy { ProgressView() }

                if !nav.summary.isEmpty {
                    Text(nav.summary).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                } else if !nav.status.isEmpty {
                    Text(nav.status).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }

                if !nav.steps.isEmpty {
                    List(Array(nav.steps.enumerated()), id: \.offset) { _, step in
                        Text(step)
                    }
                    Button("Read directions aloud") { speaker.speak(nav.spokenDirections) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Spacer()
                }
            }
            .padding()
            .navigationTitle("Navigate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func go() {
        let dest = destination.trimmingCharacters(in: .whitespaces)
        guard !dest.isEmpty else { return }
        Task {
            await nav.route(to: dest)
            if !nav.steps.isEmpty { speaker.speak(nav.spokenDirections) }
            else { speaker.speak(nav.status) }
        }
    }
}
