//
//  SignVocabView.swift
//  glasse
//
//  The experimental whole-word sign recognizer screen (signer → captions). Two
//  modes: TEACH — record each vocabulary word once so the app has a motion
//  template; READ — aim at someone signing and show the closest-matching word as
//  live captions (mirrored to the lens) with a confidence chip. Honest by design:
//  clearly experimental, single-signer, small-vocab, and never claims certainty.
//

import SwiftUI

struct SignVocabView: View {
    let reader: SignVocabReader
    var glasses: StreamSessionViewModel
    let onLens: (LensVisual) -> Void
    let onClearLens: () -> Void
    let startStream: () async -> Bool
    let stopStream: () async -> Void

    enum VocabMode: String, CaseIterable, Identifiable { case teach = "Teach", read = "Read"; var id: String { rawValue } }

    @Environment(\.dismiss) private var dismiss
    @State private var mode: VocabMode = .teach
    @State private var isReading = false
    @State private var recordingWord: String?
    @State private var pumping = false
    @State private var pump: Task<Void, Never>?

    private let vocab = SignAssets.recognitionVocab

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    disclaimer
                    Picker("Mode", selection: $mode) {
                        ForEach(VocabMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    aimView
                    if mode == .teach { teachSection } else { readSection }
                }
                .padding()
            }
            .navigationTitle("Sign → captions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { stopAll(); dismiss() } }
            }
        }
        .onChange(of: mode) { _, _ in stopAll() }
        .onChange(of: reader.lastTaught) { _, taught in
            if let taught, taught == recordingWord { recordingWord = nil; stopPump() }
        }
        .onChange(of: reader.transcript) { _, t in if mode == .read, !t.isEmpty { onLens(.text(title: "Signs", body: t)) } }
        .onDisappear { stopAll() }
    }

    // MARK: Shared pieces

    private var disclaimer: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Experimental. Recognizes a few **taught** signs from one person, signed slowly and clearly, one at a time — best-effort, not reliable transcription and not an interpreter.")
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
                    if pumping {
                        Label(reader.capturing ? "Capturing…" : (reader.handPresent ? "Hand detected" : "No hand"),
                              systemImage: reader.handPresent ? "hand.raised.fill" : "hand.raised.slash")
                            .font(.caption.weight(.semibold))
                            .padding(6).background(.ultraThinMaterial, in: Capsule()).padding(8)
                    }
                }
                .accessibilityLabel("Glasses camera view")
        } else {
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 150)
                .overlay(Text(pumping ? "Starting camera…" : "Camera preview appears here.")
                    .font(.subheadline).foregroundStyle(.secondary))
        }
    }

    // MARK: Teach

    private var taughtCount: Int { reader.store.taughtLabels.intersection(vocab.map { $0.uppercased() }).count }

    private var teachSection: some View {
        VStack(spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Taught \(taughtCount) of \(vocab.count)").font(.subheadline.weight(.semibold))
                    Text("Tap a word, do its sign once, then lower your hand. Record it yourself so it matches your signing.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if let word = recordingWord {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Recording “\(word.capitalized)”…", systemImage: "record.circle").foregroundStyle(.red).font(.headline)
                        Text(SignAssets.signText(for: word)).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        Text("Do the sign now, then lower your hand to save.").font(.caption).foregroundStyle(.secondary)
                        Button("Cancel") { recordingWord = nil; stopPump() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }

            ForEach(vocab, id: \.self) { word in
                let taught = reader.store.taughtLabels.contains(word.uppercased())
                Button { record(word) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: taught ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(taught ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(word.capitalized).font(.body.weight(.semibold)).foregroundStyle(.primary)
                            Text(SignAssets.signText(for: word)).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Text(taught ? "Redo" : "Record").font(.caption.weight(.semibold)).foregroundStyle(.indigo)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(recordingWord != nil && recordingWord != word)
            }
        }
    }

    // MARK: Read

    private var readSection: some View {
        VStack(spacing: 12) {
            Card {
                HStack(spacing: 16) {
                    Text(readGlyph)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .frame(minWidth: 96, minHeight: 64)
                        .padding(.horizontal, 8)
                        .background(chipColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(chipColor)
                        .contentTransition(.opacity)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recognized").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                        Label(confidenceText, systemImage: "gauge.with.dots.needle.50percent")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(chipColor)
                    }
                    Spacer(minLength: 0)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Captions").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    Text(reader.transcript.isEmpty ? (isReading ? "Watching for signs…" : "—") : reader.transcript)
                        .font(.title2).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
            }

            if taughtCount == 0 {
                Text("Teach at least one word first.").font(.caption).foregroundStyle(.orange)
            }

            Button(isReading ? "Stop" : "Start") { toggleReading() }
                .buttonStyle(PrimaryButtonStyle(fill: isReading ? Theme.gradient(.red) : Theme.brand))
                .disabled(taughtCount == 0)
            Button("Clear captions") { reader.clearTranscript(); onClearLens() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(reader.transcript.isEmpty)
        }
    }

    private var readGlyph: String {
        if !isReading { return "—" }
        if reader.currentWord.isEmpty || reader.currentLevel == .low { return "(?)" }
        return reader.currentWord.capitalized
    }
    private var chipColor: Color {
        switch reader.currentLevel { case .high: return .green; case .medium: return .orange; case .low: return .secondary }
    }
    private var confidenceText: String {
        guard isReading else { return "Tap Start" }
        if reader.currentWord.isEmpty { return reader.statusNote.isEmpty ? "Watching…" : reader.statusNote }
        switch reader.currentLevel {
        case .high: return "High confidence"
        case .medium: return "Medium confidence"
        case .low: return "Low — not sure"
        }
    }

    // MARK: Control

    private func record(_ word: String) {
        isReading = false
        recordingWord = word
        reader.startTeaching(word)
        startPump()
    }

    private func toggleReading() {
        if isReading { isReading = false; stopPump() }
        else { recordingWord = nil; isReading = true; reader.startReading(); startPump() }
    }

    private func startPump() {
        guard pump == nil else { return }
        pumping = true
        pump = Task {
            let ok = await startStream()
            guard ok else { stopAll(); return }
            guard pumping, !Task.isCancelled else { await stopStream(); return }
            while pumping && !Task.isCancelled {
                if let frame = glasses.currentVideoFrame { await reader.process(frame) }
                try? await Task.sleep(nanoseconds: 70_000_000)   // ~14 fps
            }
        }
    }

    private func stopPump() {
        let p = pump
        pumping = false
        pump = nil
        reader.stop()
        p?.cancel()
        Task { await p?.value; await stopStream() }
    }

    private func stopAll() {
        isReading = false
        recordingWord = nil
        if pump != nil { stopPump() }
        onClearLens()
    }
}
