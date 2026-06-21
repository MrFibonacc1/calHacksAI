//
//  SignWriterView.swift
//  glasse
//
//  The experimental "Sign what I say" coach — the inverse of SignView. The wearer
//  taps Start and speaks; SignWriter transcribes on-device and a playback cursor
//  walks through the result one step at a time (a teleprompter for your hands).
//  Words we have a sign clip for show the ASL SIGN; other words are fingerspelled,
//  with the handshape shown as a real image. The current step mirrors to the lens
//  (hosted image / video via the Display API). Honest by design: clearly
//  experimental, common signs + fingerspelling, never claims to be an interpreter.
//

import SwiftUI

struct SignWriterView: View {
    let writer: SignWriter
    let onLens: (LensVisual) -> Void
    let onClearLens: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var paused = false
    @State private var slow = false
    @State private var pump: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    disclaimer
                    heardCard
                    signCard
                    controls
                }
                .padding()
            }
            .navigationTitle("Sign what I say")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { stop(); dismiss() }
                }
            }
        }
        .onChange(of: writer.current) { _, _ in mirror() }   // fires for the first step and each cursor move
        .onDisappear { stop() }
    }

    // MARK: Pieces

    private var disclaimer: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Experimental. Shows the ASL **sign** for common words and **fingerspells** the rest so you can sign it back — a best-effort coach, not fluent ASL grammar, and not a substitute for an interpreter.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    private var heardCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("You said").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Text(writer.heardText.isEmpty ? (running ? "Listening… say a word or name." : "—") : writer.heardText)
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let err = writer.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityLabel("You said. \(writer.heardText)")
    }

    private var signCard: some View {
        Card {
            HStack(spacing: 16) {
                visualTile
                VStack(alignment: .leading, spacing: 6) {
                    Text(progressText).font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                    Text(cue)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(glyph). \(cue)")
    }

    /// The tile on the PHONE: a sign badge for whole-word signs, the hosted
    /// handshape image for fingerspelled letters when available, else the glyph.
    @ViewBuilder private var visualTile: some View {
        if let step = writer.current, case .sign = step.kind {
            VStack(spacing: 6) {
                Image(systemName: "hands.sparkles.fill").font(.system(size: 30, weight: .bold))
                Text(glyph).font(.caption.weight(.bold)).lineLimit(1).minimumScaleFactor(0.5)
            }
            .frame(width: 96, height: 96)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(tint)
        } else if let uri = phoneImageURL, let url = URL(string: uri) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                case .empty: ProgressView()
                default: glyphTile
                }
            }
            .frame(width: 96, height: 96)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            glyphTile
        }
    }

    private var glyphTile: some View {
        Text(glyph)
            .font(.system(size: 64, weight: .bold, design: .rounded))
            .frame(width: 96, height: 96)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(tint)
            .contentTransition(.numericText())
            .animation(.snappy, value: glyph)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button(running ? "Stop" : "Start") { running ? stop() : start() }
                .buttonStyle(PrimaryButtonStyle(fill: running ? Theme.gradient(.red) : Theme.brand))

            HStack(spacing: 10) {
                Button(paused ? "Resume" : "Pause") { paused.toggle() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!running || !writer.hasSteps)
                Button("Restart") { writer.restart(); mirror() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!writer.hasSteps)
            }

            Button(slow ? "Speed: Slow" : "Speed: Normal") {
                slow.toggle(); writer.stepIntervalMS = slow ? 2200 : 1300
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityHint("Toggles how long each sign or handshape is shown")
        }
    }

    // MARK: Derived display

    private var glyph: String {
        guard running || writer.hasSteps else { return "—" }
        return writer.current?.glyph ?? "—"
    }
    private var cue: String {
        guard let step = writer.current else {
            return running ? "Say a word and I'll show you how to sign it." : "Tap Start, then speak."
        }
        return SignAssets.cue(for: step)
    }
    private var tint: Color {
        guard let step = writer.current else { return .secondary }
        switch step.kind {
        case .sign:           return .purple
        case .letter, .digit: return .mint
        case .space:          return .blue
        case .unsupported:    return .secondary
        }
    }
    private var progressText: String {
        guard writer.hasSteps else { return "Sign this" }
        return "Step \(writer.index + 1) of \(writer.steps.count)"
    }
    private var phoneImageURL: String? {
        guard let step = writer.current else { return nil }
        return SignAssets.phoneImageURL(for: step)
    }

    // MARK: Playback pump (advances the cursor while listening, like SignView's frame pump)

    private func start() {
        writer.reset()
        running = true
        paused = false
        pump = Task {
            await writer.start()
            guard running, !Task.isCancelled else { writer.stop(); return }
            if writer.errorMessage != nil { running = false }
            mirror()
            while running && !Task.isCancelled {
                let interval = UInt64(max(400, writer.stepIntervalMS)) * 1_000_000
                try? await Task.sleep(nanoseconds: interval)
                guard running, !Task.isCancelled else { break }
                if !paused && writer.canAdvance { writer.advance() }   // mirror() fires via onChange(current)
            }
        }
    }

    private func stop() {
        let p = pump
        let wasActive = running || p != nil
        running = false
        pump = nil
        p?.cancel()
        writer.stop()
        guard wasActive else { return }
        onClearLens()   // clear stale content off the lens
    }

    /// Mirror the current step to the lens as the right visual (sign video,
    /// handshape image, or text cue — resolved by SignAssets).
    private func mirror() {
        guard let step = writer.current, running else { return }
        onLens(SignAssets.lensVisual(for: step))
    }
}
