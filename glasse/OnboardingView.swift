//
//  OnboardingView.swift
//  glasse
//
//  A clean, accessible welcome shown on first launch. Introduces what the app
//  does and hands off to the main screen. Designed VoiceOver-first: a single
//  scrollable page (no swipe-only carousel), clear headings, and one big CTA.
//

import SwiftUI

struct OnboardingView: View {
    let onDone: () -> Void

    private struct Highlight: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let title: String
        let detail: String
    }

    private let highlights: [Highlight] = [
        .init(icon: "eye.fill", tint: .indigo,
              title: "See with sound",
              detail: "Your glasses describe what's in front of you, spoken aloud."),
        .init(icon: "captions.bubble.fill", tint: .teal,
              title: "Live captions",
              detail: "Turn nearby speech into large, readable text — on your phone or in the lens."),
        .init(icon: "location.fill", tint: .green,
              title: "Find your way",
              detail: "Spoken, step-by-step walking directions to anywhere."),
        .init(icon: "person.crop.circle.badge.checkmark", tint: .orange,
              title: "Built around you",
              detail: "Describe your needs and we build a custom assistant just for you."),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Theme.brand)
                            .frame(width: 104, height: 104)
                            .shadow(color: .indigo.opacity(0.35), radius: 18, y: 8)
                        Image(systemName: "eyeglasses")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)
                    .padding(.top, 24)

                    Text("Glasses Assist")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("An accessibility companion for your smart glasses.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                VStack(spacing: 12) {
                    ForEach(highlights) { h in
                        HStack(spacing: 14) {
                            Image(systemName: h.icon)
                                .font(.title2)
                                .foregroundStyle(h.tint)
                                .frame(width: 46, height: 46)
                                .background(h.tint.opacity(0.14), in: Circle())
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(h.title).font(.headline)
                                Text(h.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(h.title). \(h.detail)")
                    }
                }
                .padding(.horizontal, 4)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 120)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button(action: onDone) {
                    Text("Get Started")
                }
                .buttonStyle(PrimaryButtonStyle())
                Text("You can connect your glasses next, or try it with your phone camera.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .background(.ultraThinMaterial)
        }
        .background(backgroundGradient.ignoresSafeArea())
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color.indigo.opacity(0.10), Color.clear],
            startPoint: .top, endPoint: .center)
    }
}

#Preview {
    OnboardingView(onDone: {})
}
