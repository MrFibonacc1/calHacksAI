//
//  SignView.swift
//  glasse
//
//  The experimental "Fingerspelling reader" screen. Aims the glasses camera at a
//  person fingerspelling, runs SignReader on the live frames, shows the current
//  letter + a confidence chip and the assembled words, and mirrors the captions
//  to the in-lens display. Honest by design: clearly experimental, shows
//  uncertainty, and never claims to be an ASL interpreter.
//

import SwiftUI

struct SignView: View {
    let reader: SignReader
    var glasses: StreamSessionViewModel
    let onLens: (String, String) -> Void
    let startStream: () async -> Bool
    let stopStream: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var pump: Task<Void, Never>?
    @State private var status = "Tap Start, then aim at the person fingerspelling."

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    disclaimer
                    aimView
                    letterCard
                    transcriptCard
                    controls
                }
                .padding()
            }
            .navigationTitle("Fingerspelling")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { stop(); dismiss() }
                }
            }
        }
        .onChange(of: reader.transcript) { _, t in
            if !t.isEmpty { onLens("Fingerspelling", t) }
        }
        .onDisappear { stop() }
    }

    // MARK: Pieces

    private var disclaimer: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Experimental. Reads slow, clear, front-facing **fingerspelling** — not full ASL, and not a substitute for an interpreter.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    @ViewBuilder private var aimView: some View {
        if let frame = glasses.currentVideoFrame {
            Image(uiImage: frame)
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if running {
                        Label(reader.handPresent ? "Hand detected" : "No hand",
                              systemImage: reader.handPresent ? "hand.raised.fill" : "hand.raised.slash")
                            .font(.caption.weight(.semibold))
                            .padding(6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
                }
                .accessibilityLabel("Glasses camera view")
        } else {
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 150)
                .overlay(Text(running ? "Starting camera…" : status)
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding())
        }
    }

    private var letterCard: some View {
        Card {
            HStack(spacing: 16) {
                Text(liveGlyph)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 96, height: 96)
                    .background(chipColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(chipColor)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: liveGlyph)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Current letter").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                    Label(confidenceText, systemImage: "gauge.with.dots.needle.50percent")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(chipColor)
                    Text("Hold a letter steady to add it. Open your hand for a space.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current letter \(liveGlyph), \(confidenceText)")
    }

    private var transcriptCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Captions").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Text(reader.transcript.isEmpty ? (running ? "Listening for letters…" : "—") : reader.transcript)
                    .font(.title2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityLabel("Captions. \(reader.transcript)")
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button(running ? "Stop" : "Start") { running ? stop() : start() }
                .buttonStyle(PrimaryButtonStyle(fill: running ? Theme.gradient(.red) : Theme.brand))
            Button("Clear") { reader.reset(); onLens("Fingerspelling", " ") }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(reader.transcript.isEmpty)
        }
    }

    // MARK: Derived display

    /// What to show in the big glyph: the live letter, "(?)" when uncertain but a
    /// hand is present, or a dash when idle.
    private var liveGlyph: String {
        if !running { return "—" }
        if !reader.handPresent { return "·" }
        if reader.currentLetter.isEmpty || reader.currentLevel == .low { return "(?)" }
        return reader.currentLetter
    }
    private var chipColor: Color {
        switch reader.currentLevel {
        case .high: return .green
        case .medium: return .orange
        case .low: return .secondary
        }
    }
    private var confidenceText: String {
        guard running, reader.handPresent, !reader.currentLetter.isEmpty else { return "Waiting…" }
        switch reader.currentLevel {
        case .high: return "High confidence"
        case .medium: return "Medium confidence"
        case .low: return "Low — not sure"
        }
    }

    // MARK: Frame pump

    private func start() {
        reader.reset()
        running = true
        reader.isRunning = true
        pump = Task {
            let ok = await startStream()
            if !ok {
                status = "Couldn't start the glasses camera."
                running = false; reader.isRunning = false
                return
            }
            // Stopped/dismissed while the stream was starting? Cancellation can't
            // abort an in-flight start, so tear it down here ourselves.
            guard running, !Task.isCancelled else { await stopStream(); return }
            while running && !Task.isCancelled {
                if let frame = glasses.currentVideoFrame { await reader.process(frame) }
                try? await Task.sleep(nanoseconds: 80_000_000)   // ~12 fps
            }
        }
    }

    private func stop() {
        let p = pump
        let wasActive = running || p != nil
        running = false
        reader.isRunning = false
        pump = nil
        p?.cancel()
        guard wasActive else { return }
        onLens("Fingerspelling", " ")   // clear stale captions off the lens
        // Await the pump so an in-flight start fully returns before we tear down.
        Task { await p?.value; await stopStream() }
    }
}
