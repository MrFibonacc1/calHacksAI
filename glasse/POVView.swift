//
//  POVView.swift
//  glasse
//
//  Full-screen live view of what the glasses see, with an overlaid Describe
//  button and a close button.
//

import SwiftUI

struct POVView: View {
    let glasses: StreamSessionViewModel
    let caption: String
    let isWorking: Bool
    let detections: [ObjectDetector.Detection]
    let onDescribe: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let frame = glasses.currentVideoFrame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .accessibilityLabel("Live view from the glasses camera")
            } else {
                ProgressView("Starting glasses view…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .overlay(alignment: .topLeading) {
            if !detections.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(detections) { d in
                        Text("\(d.label)  ·  \(Int(d.confidence * 100))%")
                            .font(.caption).foregroundStyle(.white)
                    }
                }
                .padding(8)
                .background(Theme.overlayScrim)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding()
            }
        }
        .overlay {

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                    .padding()
                    .accessibilityLabel("Close full screen")
                }

                Spacer()

                if !caption.isEmpty {
                    Text(caption)
                        .font(.title3)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Theme.overlayScrim)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal)
                }

                Button(action: onDescribe) {
                    Text(isWorking ? "Looking…" : "Describe")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isWorking)
                .padding()
            }
        }
    }
}
