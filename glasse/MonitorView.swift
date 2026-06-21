//
//  MonitorView.swift
//  glasse
//
//  A "monitor a loved one" screen: shows the wearer on a map together with a
//  live thumbnail of what their glasses see. This build is single-device and
//  local — it monitors the person wearing THIS phone's glasses (useful for a
//  caregiver holding the phone). True remote multi-wearer monitoring needs a
//  companion backend (AWS / GCP / Azure) to share location + frames between
//  accounts; the data model here (`[MonitoredWearer]`) is shaped so remote
//  wearers can be added later without reworking the UI.
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Location

/// Publishes the device's current coordinate with continuous updates.
@Observable
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    var coordinate: CLLocationCoordinate2D?
    var lastUpdate: Date?
    var denied = false

    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() { manager.stopUpdatingLocation() }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        Task { @MainActor in
            self.coordinate = loc.coordinate
            self.lastUpdate = Date()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let status = m.authorizationStatus
        Task { @MainActor in
            self.denied = (status == .denied || status == .restricted)
        }
    }
}

// MARK: - Wearer model

/// One monitored person. Today there is exactly one (the local wearer); the
/// shape supports remote wearers in a future networked build.
struct MonitoredWearer: Identifiable {
    let id = UUID()
    var name: String
    var isLocal: Bool
    var coordinate: CLLocationCoordinate2D?
    var lastUpdate: Date?
}

// MARK: - View

struct MonitorView: View {
    let glasses: StreamSessionViewModel
    let wearerName: String
    /// Starts the glasses stream (idempotent), returning whether it actually
    /// started. Provided by ContentView so the monitor reuses the same
    /// mock/real streaming path.
    let startCamera: () async -> Bool
    let stopCamera: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var provider = LocationProvider()
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var cameraOn = false
    @State private var isStarting = false
    @State private var cameraError: String?

    private var wearer: MonitoredWearer {
        MonitoredWearer(name: wearerName, isLocal: true,
                        coordinate: provider.coordinate, lastUpdate: provider.lastUpdate)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                map
                statusCard
            }
            .navigationTitle("Monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { recenter() } label: { Image(systemName: "location.fill") }
                        .accessibilityLabel("Recenter map")
                }
            }
        }
        .onAppear { provider.start() }
        .onDisappear {
            provider.stop()
            if cameraOn { Task { await stopCamera(); cameraOn = false } }
        }
    }

    // MARK: Map

    private var map: some View {
        Map(position: $position) {
            if let coord = provider.coordinate {
                Annotation(wearer.name, coordinate: coord) {
                    ZStack {
                        Circle().fill(Theme.brand).frame(width: 40, height: 40)
                            .shadow(radius: 4, y: 2)
                        Image(systemName: "eyeglasses")
                            .font(.headline).foregroundStyle(.white)
                    }
                    .accessibilityLabel("\(wearer.name)'s location")
                }
            }
            UserAnnotation()
        }
        .mapControls { MapCompass() }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: Status / POV card

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle().fill(cameraOn ? .green : .secondary).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(wearer.name).font(.headline)
                        Text(statusLine).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                povThumbnail

                HStack(spacing: 10) {
                    Button {
                        Task {
                            if cameraOn {
                                await stopCamera(); cameraOn = false
                            } else {
                                cameraError = nil
                                isStarting = true
                                let ok = await startCamera()
                                isStarting = false
                                cameraOn = ok
                                if !ok { cameraError = "Couldn't start the glasses camera. Try again." }
                            }
                        }
                    } label: {
                        Label(cameraButtonTitle,
                              systemImage: cameraOn ? "stop.circle" : "video.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle(tint: cameraOn ? .red : .accentColor))
                    .disabled(isStarting)
                }

                if provider.denied {
                    Text("Location access is off. Turn it on in Settings to see the map.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let cameraError {
                    Text(cameraError).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var povThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.85))
            if cameraOn, let frame = glasses.currentVideoFrame {
                Image(uiImage: frame)
                    .resizable().scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("Live view from \(wearer.name)'s glasses")
            } else {
                let connecting = isStarting || (cameraOn && glasses.currentVideoFrame == nil)
                VStack(spacing: 6) {
                    Image(systemName: connecting ? "hourglass" : "video.slash.fill")
                        .font(.title2).foregroundStyle(.white.opacity(0.7))
                    Text(connecting ? "Connecting to camera…" : "Camera off")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(height: 170)
        .frame(maxWidth: .infinity)
    }

    private var statusLine: String {
        if provider.coordinate == nil { return "Locating…" }
        guard let t = provider.lastUpdate else { return "Located" }
        let secs = Int(Date().timeIntervalSince(t))
        if secs < 5 { return "Live now" }
        if secs < 60 { return "Updated \(secs)s ago" }
        return "Updated \(secs / 60)m ago"
    }

    private var cameraButtonTitle: String {
        if isStarting { return "Connecting…" }
        return cameraOn ? "Stop live view" : "See their view"
    }

    private func recenter() {
        if let coord = provider.coordinate {
            withAnimation {
                position = .region(MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
            }
        } else {
            position = .userLocation(fallback: .automatic)
        }
    }
}
