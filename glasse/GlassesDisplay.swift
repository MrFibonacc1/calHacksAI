//
//  GlassesDisplay.swift
//  glasse
//
//  Sends short text to the in-lens display of the Meta Ray-Ban Display glasses.
//  Modeled on Meta's official DisplayAccess sample (DisplayViewModel).
//
//  ⚠️ This path is gated behind `canImport(MWDATDisplay)`: it only compiles once
//  you add the MWDATDisplay product in Swift Package Manager, and it can only be
//  *run* on real Display hardware — the Mock Device Kit cannot drive the lens
//  display. Until then, agents whose outputMode is `.glassesDisplay` fall back
//  to on-phone text (see ContentView.sink(for:)).
//

#if canImport(MWDATDisplay)
import Foundation
import MWDATCore
import MWDATDisplay
import Observation

@Observable
@MainActor
final class GlassesDisplayManager {
    private(set) var isConnected = false
    /// Human-readable connection state, surfaced on the phone for debugging.
    private(set) var status = "Not connected"

    @ObservationIgnored private let wearables: WearablesInterface = Wearables.shared
    @ObservationIgnored private var deviceSelector: AutoDeviceSelector
    /// The SHARED device session (the same one the camera uses). When set, the lens
    /// attaches to it via addDisplay() instead of creating its own session — MWDAT
    /// allows only one session per device, so a second one throws "session already
    /// exists for this device" whenever the camera is also running.
    @ObservationIgnored private var sessionManager: DeviceSessionManager?
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var display: Display?
    @ObservationIgnored private var stateToken: AnyListenerToken?
    @ObservationIgnored private var coreStateTask: Task<Void, Never>?
    @ObservationIgnored private var displayStateTask: Task<Void, Never>?
    @ObservationIgnored private var pending: LensVisual?
    @ObservationIgnored private var isAttaching = false
    /// Auto-clear: TEXT left on the lens disappears after this idle period. Each
    /// new text render restarts the timer, so live captions stay up while speech
    /// continues and only clear after a quiet stretch. Image/video (sign content)
    /// are NOT auto-cleared — they persist until replaced, so a sign the user is
    /// studying isn't yanked away.
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    /// Bumped on every successful render; the auto-dismiss captures the value it was
    /// armed at and bails if newer content has since landed (so a clear in flight
    /// can't wipe a fresh render).
    @ObservationIgnored private var renderGen = 0
    private static let autoDismissNanos: UInt64 = 10 * 1_000_000_000   // 10s

    /// Wire the lens to the camera's shared device session. Call once (e.g. on
    /// appear) so the display attaches to the existing session instead of opening a
    /// second, conflicting one.
    func use(_ manager: DeviceSessionManager) {
        sessionManager = manager
    }

    init() {
        deviceSelector = AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
    }

    /// Shows a titled text card on the lens (back-compat convenience).
    func show(title: String = "Glasses Assist", body: String) async {
        await show(.text(title: title, body: body))
    }

    /// Shows any lens visual — text, a hosted handshape image, or a hosted sign
    /// video — attaching to the display first if needed.
    func show(_ visual: LensVisual) async {
        if let display, isConnected {
            await render(visual, on: display)
        } else {
            pending = visual               // coalesces; latest wins
            if display == nil && !isAttaching { await attach() }
        }
    }

    private func render(_ visual: LensVisual, on display: Display) async {
        do {
            switch visual {
            case .video(_, let uri, _):
                // Video must be sent as a ROOT VideoPlayer (per the Display API).
                try await display.send(VideoPlayer(provider: .uri(uri), codec: .mp4))
                status = "Connected — playing sign"
            case .image(let title, let uri, let caption):
                let view = FlexBox(direction: .column, spacing: 8) {
                    Text(title, style: .heading, color: .secondary)
                    Image(uri: uri, sizePreset: .fill, cornerRadius: .medium)
                    Text(caption, style: .body)
                }
                try await display.send(view)
                status = "Connected — showing handshape"
            case .text(let title, let body):
                let view = FlexBox(direction: .column, spacing: 8) {
                    Text(title, style: .heading, color: .secondary)
                    Text(body, style: .body)
                }
                try await display.send(view)
                status = "Connected — showing text"
            }
            renderGen &+= 1   // fresh content landed
            // Only auto-clear TEXT (captions). Sign image/video persist until
            // replaced; just cancel any timer a prior text render left armed so it
            // can't blank the sign.
            if case .text = visual {
                scheduleAutoDismiss(gen: renderGen)
            } else {
                dismissTask?.cancel(); dismissTask = nil
            }
        } catch {
            status = "Couldn't send to display: \(error.localizedDescription)"
        }
    }

    /// (Re)arm the idle timer that blanks the lens. Cancelled/restarted by the next
    /// render, so continuous text (live captions) never clears mid-conversation.
    private func scheduleAutoDismiss(gen: Int) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.autoDismissNanos)
            guard let self, !Task.isCancelled else { return }
            await self.clear(ifGen: gen)
        }
    }

    /// Blanks the lens. The Display API we use has no dedicated clear, so we send a
    /// near-empty card (a single blank line) — enough to remove the visible text.
    /// `ifGen`, when set, makes this a no-op if newer content rendered since the
    /// timer was armed (so an idle-clear can't wipe a fresh render).
    func clear(ifGen gen: Int? = nil) async {
        if let gen, gen != renderGen { return }   // superseded by newer content
        dismissTask?.cancel(); dismissTask = nil
        pending = nil
        guard let display, isConnected else { return }
        do {
            try await display.send(FlexBox(direction: .column, spacing: 8) {
                Text(" ", style: .body)
            })
            status = "Connected — cleared"
        } catch {
            status = "Couldn't clear display: \(error.localizedDescription)"
        }
    }

    private func attach() async {
        guard display == nil, !isAttaching else { return }
        isAttaching = true
        status = "Connecting to glasses display…"

        // Preferred: attach the display to the SHARED device session (the one the
        // camera uses). getSession() returns a started session — reused if it
        // already exists, created if not — so we never open a second session for
        // the device ("session already exists for this device").
        if let sessionManager {
            do {
                let session = try await sessionManager.getSession()
                self.session = session
                await setupDisplay(on: session)
            } catch {
                isConnected = false
                isAttaching = false
                status = "Display unavailable: \(error.localizedDescription)"
            }
            return
        }

        // Fallback (no shared session wired): our own display-only session.
        do {
            let session = try wearables.createSession(deviceSelector: deviceSelector)
            self.session = session
            let stateStream = session.stateStream()
            coreStateTask = Task { [weak self] in
                for await state in stateStream {
                    guard let self, !Task.isCancelled else { return }
                    switch state {
                    case .started: await self.setupDisplay(on: session)
                    case .stopping, .stopped:
                        self.isConnected = false; self.display = nil; self.isAttaching = false
                        self.status = "Disconnected"
                    default: break
                    }
                }
            }
            try session.start()
        } catch {
            isConnected = false
            isAttaching = false
            status = "No display-capable glasses found: \(error.localizedDescription)"
        }
    }

    private func setupDisplay(on session: DeviceSession) async {
        guard display == nil else { return }
        do {
            let capability = try session.addDisplay()
            let (stream, continuation) = AsyncStream.makeStream(of: DisplayState.self)
            stateToken = capability.statePublisher.listen { continuation.yield($0) }
            displayStateTask = Task { [weak self] in
                for await state in stream {
                    guard let self, !Task.isCancelled else { return }
                    switch state {
                    case .started:
                        self.isConnected = true
                        self.status = "Connected"
                        if let pending = self.pending {
                            self.pending = nil
                            await self.render(pending, on: capability)
                        }
                    case .stopped:
                        self.isConnected = false; self.display = nil; self.isAttaching = false
                        self.status = "Disconnected"
                    default: break
                    }
                }
            }
            await capability.start()
            display = capability
            isAttaching = false
        } catch {
            isConnected = false
            isAttaching = false
            status = "Display unavailable: \(error.localizedDescription)"
        }
    }
}

/// Routes a description/caption to the in-lens display.
@MainActor
struct GlassesDisplaySink: OutputSink {
    let manager: GlassesDisplayManager
    func deliver(_ text: String) {
        Task { await manager.show(body: text) }
    }
}
#endif
