//
//  Theme.swift
//  glasse
//
//  App-wide design system: colors, gradients, reusable button styles, and a
//  card container. Tuned for accessibility — large tap targets, high contrast,
//  Dynamic Type, and full dark-mode support via system colors/materials.
//

import SwiftUI

enum Theme {
    /// Brand gradient used for the primary action and accents.
    static let brand = LinearGradient(
        colors: [Color(red: 0.33, green: 0.34, blue: 0.95),
                 Color(red: 0.52, green: 0.30, blue: 0.96)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let corner: CGFloat = 18
    static let cardCorner: CGFloat = 22
    static let bubbleCorner: CGFloat = 14
    static let controlHeight: CGFloat = 60

    // Shared surfaces so screens stop hardcoding opacity literals.
    static let userBubble = Color.accentColor.opacity(0.18)
    static let assistantBubble = Color.gray.opacity(0.15)
    static let cardFill = Color.gray.opacity(0.10)
    static let overlayScrim = Color.black.opacity(0.55)

    /// A soft tint gradient from any base color (for stateful buttons).
    static func gradient(_ base: Color) -> LinearGradient {
        LinearGradient(colors: [base, base.opacity(0.82)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Button styles

/// Large, filled, gradient primary action. White label, generous tap target.
struct PrimaryButtonStyle: ButtonStyle {
    var fill: LinearGradient = Theme.brand
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: Theme.controlHeight)
            .padding(.horizontal, 12)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .shadow(color: .black.opacity(configuration.isPressed ? 0.05 : 0.18),
                    radius: configuration.isPressed ? 3 : 10, y: configuration.isPressed ? 1 : 5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Tinted, lighter-weight secondary action used for the feature list.
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 14)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Card container

/// A rounded "card" surface with material background and a hairline border.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                    .strokeBorder(.white.opacity(0.06))
            )
    }
}

// MARK: - Feature row

/// The visual content of a feature row (SF Symbol in a tinted circle +
/// title/subtitle + a trailing glyph). Shared by `FeatureRow` (a Button) and
/// PhotosPicker labels so every row looks identical.
struct FeatureRowLabel: View {
    let icon: String
    let title: String
    let subtitle: String
    var tint: Color = .accentColor
    var trailingSystemImage: String = "chevron.right"

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            Image(systemName: trailingSystemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

/// Full-screen overlay shown while the voice agent is listening: a pulsing mic,
/// the live transcript, and a cancel affordance. Designed to be obvious to a
/// user or a helper standing nearby.
struct ListeningOverlay: View {
    let heard: String
    let onCancel: () -> Void
    @State private var pulse = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
                .onTapGesture(perform: onCancel)
            VStack(spacing: 22) {
                ZStack {
                    Circle().fill(Theme.brand)
                        .frame(width: 116, height: 116)
                        .scaleEffect(pulse ? 1.12 : 0.9)
                        .opacity(pulse ? 0.85 : 1)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
                }
                Text("Listening…").font(.title.bold())
                Text(heard.isEmpty ? "Speak your command" : heard)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 56)
                    .padding(.horizontal, 8)
                Button("Cancel", action: onCancel)
                    .buttonStyle(SecondaryButtonStyle(tint: .red))
                    .padding(.horizontal, 32)
            }
            .padding(28)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(32)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Listening. " + (heard.isEmpty ? "Speak your command." : heard))
        .accessibilityAddTraits(.isModal)
    }
}

/// A tappable feature row with a VoiceOver label and hint.
struct FeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var tint: Color = .accentColor
    var hint: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FeatureRowLabel(icon: icon, title: title, subtitle: subtitle, tint: tint)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
    }
}
