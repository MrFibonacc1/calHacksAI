//
//  GlassesMock.swift
//  glasse
//
//  Simulator-only: spins up a simulated Ray-Ban Meta device fed by bundled
//  sample media (plant.mp4 / plant.png), so the pipeline runs end-to-end with
//  no physical hardware. On a real device this is excluded entirely and the app
//  connects to the actual glasses via the registration flow instead.
//

#if targetEnvironment(simulator)
import Foundation
import MWDATMockDevice

enum GlassesMock {
    private static var started = false

    @MainActor
    static func startIfNeeded() async {
        guard !started else { return }
        started = true

        MockDeviceKit.shared.enable()
        let device = MockDeviceKit.shared.pairRaybanMeta()
        let camera = device.services.camera

        device.powerOn()
        device.unfold()
        device.don()

        if let video = Bundle.main.url(forResource: "plant", withExtension: "mp4") {
            camera.setCameraFeed(fileURL: video)
        }
        if let image = Bundle.main.url(forResource: "plant", withExtension: "png") {
            camera.setCapturedImage(fileURL: image)
        }

        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }
}
#endif
