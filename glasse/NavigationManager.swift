//
//  NavigationManager.swift
//  glasse
//
//  Walking directions to a destination using Apple Maps (native, no account):
//  gets the user's location, looks up the destination, computes a walking
//  route, and exposes spoken-friendly step instructions. Pairs with the vision
//  agent so the user can describe surroundings while following the route.
//

import Foundation
import CoreLocation
import MapKit
import Observation

@Observable
@MainActor
final class NavigationManager: NSObject {
    var steps: [String] = []
    var summary: String = ""
    var status: String = ""
    var isBusy = false

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    @ObservationIgnored private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Computes a walking route to `destination` and fills `steps`/`summary`.
    func route(to destination: String) async {
        isBusy = true
        status = "Finding your location…"
        steps = []
        summary = ""
        defer { isBusy = false }

        manager.requestWhenInUseAuthorization()
        var auth = manager.authorizationStatus
        if auth == .notDetermined {
            auth = await awaitAuthorization()   // wait for the prompt, don't race it
        }
        if auth == .denied || auth == .restricted {
            status = "Location access is off. Turn it on in Settings to get directions."
            return
        }
        guard let origin = await currentLocation() else {
            status = "Couldn't get your location. Make sure Location Services are on."
            return
        }

        status = "Looking up \(destination)…"
        let search = MKLocalSearch.Request()
        search.naturalLanguageQuery = destination
        search.region = MKCoordinateRegion(center: origin.coordinate,
                                            latitudinalMeters: 30000, longitudinalMeters: 30000)
        do {
            let results = try await MKLocalSearch(request: search).start()
            guard let dest = results.mapItems.first else {
                status = "Couldn't find \(destination)."
                return
            }

            let req = MKDirections.Request()
            req.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
            req.destination = dest
            req.transportType = .walking
            let directions = try await MKDirections(request: req).calculate()
            guard let route = directions.routes.first else {
                status = "No walking route found."
                return
            }

            steps = route.steps.map(\.instructions).filter { !$0.isEmpty }
            let minutes = max(1, Int((route.expectedTravelTime / 60).rounded()))
            let meters = Int(route.distance)
            summary = "About \(minutes) min, \(meters) meters to \(dest.name ?? destination)."
            status = summary
        } catch {
            status = "Navigation error: \(error.localizedDescription)"
        }
    }

    /// A single spoken string combining the summary and the turn list.
    var spokenDirections: String {
        ([summary] + steps).joined(separator: ". ")
    }

    /// Waits for the first authorization decision (or 10s), so a slow "Allow"
    /// tap doesn't get misread as a missing location.
    private func awaitAuthorization() async -> CLAuthorizationStatus {
        await withCheckedContinuation { (c: CheckedContinuation<CLAuthorizationStatus, Never>) in
            authContinuation = c
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if let cont = self.authContinuation {
                    self.authContinuation = nil
                    cont.resume(returning: self.manager.authorizationStatus)
                }
            }
        }
    }

    private func currentLocation() async -> CLLocation? {
        if let loc = manager.location { return loc }
        manager.startUpdatingLocation()
        let loc = await withCheckedContinuation { (c: CheckedContinuation<CLLocation?, Never>) in
            locationContinuation = c
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if let cont = self.locationContinuation {
                    self.locationContinuation = nil
                    cont.resume(returning: self.manager.location)
                }
            }
        }
        manager.stopUpdatingLocation()
        return loc
    }
}

extension NavigationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            if let cont = self.locationContinuation {
                self.locationContinuation = nil
                cont.resume(returning: locations.last)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if let cont = self.authContinuation {
                self.authContinuation = nil
                cont.resume(returning: status)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if let cont = self.locationContinuation {
                self.locationContinuation = nil
                cont.resume(returning: nil)   // don't block for the full timeout on a hard failure
            }
        }
    }
}
