//
//  ContentView.swift
//  glasse
//

import SwiftUI
import AVFoundation
import PhotosUI
import UIKit
import Speech
import MWDATCore

/// Speaks text aloud using the system text-to-speech voice. Routes through the
/// shared AudioCoordinator so it never clobbers a live caption microphone.
@Observable
@MainActor
final class Speaker {
    /// True while TTS is (about to be) audible. Lets the wake-word listener yield
    /// the mic so the app's own speech doesn't get muted or self-trigger it.
    private(set) var isSpeaking = false

    /// Text-to-speech master switch. When false, `speak` is a no-op (the app still
    /// shows text on screen/lens — it just doesn't talk). Toggled by voice.
    @ObservationIgnored var isEnabled = true

    /// Called synchronously at the very start of `speak`, before the recording
    /// check — the app uses it to stop the wake-word listener so its mic doesn't
    /// suppress this playback. (It must NOT touch a live caption session.)
    @ObservationIgnored var onWillSpeak: (() -> Void)?

    @ObservationIgnored private let synth = AVSpeechSynthesizer()
    @ObservationIgnored private let deepgram = DeepgramTTS()
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var speakGen = 0   // only the latest speak owns isSpeaking

    func speak(_ text: String) {
        guard isEnabled, !text.isEmpty else { return }   // text-to-speech off → stay silent
        onWillSpeak?()   // yield the wake-word mic before we check the session
        guard !AudioCoordinator.shared.isRecording, !AudioCoordinator.shared.interrupted else { return }  // don't talk over the caption mic or a phone call
        AudioCoordinator.shared.beginPlayback()
        synth.stopSpeaking(at: .immediate)
        deepgram.stop()
        speakGen &+= 1
        let gen = speakGen
        isSpeaking = true
        scheduleStopSpeaking(after: 18, gen: gen)   // safety bound if the TTS request hangs
        Task {
            let spoke = await deepgram.speak(text)   // Deepgram Aura first…
            guard gen == speakGen else { return }    // a newer speak superseded us
            if spoke {
                // player.duration is 0 for a freshly-loaded MP3 until parsed, and
                // 0 is non-nil so `?? estimate` wouldn't fire — treat <=0 as unknown.
                let dur = deepgram.lastPlaybackDuration.flatMap { $0 > 0 ? $0 : nil } ?? estimatedDuration(text)
                scheduleStopSpeaking(after: dur + 0.3, gen: gen)
            } else {
                Telemetry.breadcrumb("TTS fell back to Apple voice", category: "voice")
                synth.speak(AVSpeechUtterance(string: text))   // …else Apple TTS
                scheduleStopSpeaking(after: estimatedDuration(text), gen: gen)
            }
            Telemetry.setTag("tts.engine", spoke ? "deepgram" : "apple")
        }
    }

    /// Speak `text` and wait until playback finishes, so a mic capture started
    /// right after doesn't cut the clip off. Returns at once if speech couldn't
    /// start (e.g. the caption mic already owns audio).
    func speakAndWait(_ text: String, timeout: Double = 3) async {
        speak(text)
        guard isSpeaking else { return }   // speak() bailed — nothing to wait for
        // Phase A — wait for audio to actually BEGIN. isSpeaking flips true
        // synchronously, but Deepgram Aura needs a network round-trip (up to its
        // ~6s request budget) before playback starts; the Apple-TTS fallback starts
        // ~instantly (synth.isSpeaking). Bounding this by the request budget keeps
        // `timeout` measuring playback length, not the network fetch.
        var waited = 0.0
        while isSpeaking, !deepgram.isPlaying, !synth.isSpeaking, waited < 6.5 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        // Phase B — wait for the clip to FINISH (isSpeaking clears when playback
        // ends), bounded by `timeout` so a wedged player can't strand the mic.
        waited = 0.0
        while isSpeaking, waited < timeout {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
    }

    /// Wait until any in-flight speech finishes (bounded), so a follow-on mic
    /// capture / audio-session change doesn't cut it off. `isSpeaking` is set
    /// synchronously by `speak`, so this covers the Deepgram network fetch AND the
    /// playback. No-op if nothing is speaking (e.g. TTS off).
    func finishSpeaking(timeout: Double = 30) async {
        var waited = 0.0
        while isSpeaking, waited < timeout {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
    }

    /// Estimate spoken length when there's no exact duration (Apple path):
    /// ~12 chars/sec, floored so very short replies still clear.
    private func estimatedDuration(_ text: String) -> Double { max(1.2, Double(text.count) / 12.0) }

    /// Flip `isSpeaking` off once playback should be done. Re-checks BOTH engines
    /// (`synth.isSpeaking` for Apple, `deepgram.isPlaying` for Aura) so a still-
    /// audible clip defers the flip; `gen` ensures a superseded call can't clear a
    /// newer one. Clamped so a bad duration can't strand the wake listener.
    private func scheduleStopSpeaking(after seconds: Double, gen: Int, rechecks: Int = 12) {
        stopTask?.cancel()
        stopTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(min(max(0, seconds), 30) * 1_000_000_000))
            guard !Task.isCancelled, gen == speakGen else { return }
            // Defer while audio is still going — but cap the re-check chain so a
            // wedged synth can't strand the wake listener forever.
            if rechecks > 0, synth.isSpeaking || deepgram.isPlaying {
                scheduleStopSpeaking(after: 0.4, gen: gen, rechecks: rechecks - 1)
                return
            }
            isSpeaking = false
            AudioCoordinator.shared.endPlayback()
        }
    }
}

/// Throttles live-caption updates that are pushed to the in-lens display so it
/// isn't redrawn on every partial result.
@MainActor
final class CaptionRouter {
    private var last = Date.distantPast
    private var latest = ""
    private var pending: Task<Void, Never>?

    private var deliver: ((String) -> Void)?

    /// Throttled delivery with a trailing-edge flush, so the final (most
    /// complete) caption always reaches the lens instead of being dropped.
    func route(_ text: String, minInterval: TimeInterval = 1.2, deliver: @escaping (String) -> Void) {
        self.deliver = deliver
        latest = text
        let now = Date()
        let elapsed = now.timeIntervalSince(last)
        if elapsed >= minInterval {
            pending?.cancel(); pending = nil
            last = now
            deliver(text)
        } else {
            pending?.cancel()
            let wait = minInterval - elapsed
            pending = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.last = Date()
                self.deliver?(self.latest)
                self.pending = nil
            }
        }
    }

    func reset() {
        pending?.cancel(); pending = nil
        last = .distantPast
        latest = ""
        deliver = nil
    }
}

/// Watches a live caption transcript for an inline "Glasses <command>" and
/// fires the command ONCE — after it stops growing (debounce across consecutive
/// finalized segments, so "glasses swap" → waits → "glasses swap to sign
/// language" isn't truncated when a mid-sentence pause finalizes the first part)
/// and without re-firing the same command as it lingers in the transcript (dedup).
/// `consider` is fed FINALIZED segments only (see SpeechCaptioner.onUpdate's
/// isFinal flag), so the timer just coalesces multi-segment commands.
@MainActor
final class CaptionCommandRouter {
    /// Shortest NON-EMPTY command we'll act on. A bare wake (empty command — just
    /// "glasses") IS allowed: it opens a "Yes?" listen. But a 1-character tail
    /// is almost always STT noise ("glasses. a"), so ignore that.
    private static let minCommandLength = 2

    private var pending: Task<Void, Never>?
    private var seen: String?        // command currently being debounced (nil = none)
    private var lastFired: String?   // last command dispatched (nil = none yet)

    /// Call on every FINALIZED caption segment. `fire` runs at most once per
    /// distinct, settled command. An empty command means a bare wake.
    func consider(_ transcript: String, settle: TimeInterval = 1.5, fire: @escaping (String) -> Void) {
        guard let cmd = WakeWord.commandInTranscript(transcript),
              cmd.isEmpty || cmd.count >= Self.minCommandLength,
              cmd != lastFired else { return }
        if cmd == seen { return }   // same in-progress command — let the running timer settle it
        seen = cmd
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // Fire the command CAPTURED at detection — do NOT re-extract from the
            // latest transcript. Finalized segments are immutable (the command can't
            // grow on its line during the settle), and re-scanning a transcript that
            // has since accumulated more finals could miss the "glasses" line once
            // it scrolls out of commandInTranscript's last-6-line window, or pick up a
            // later speaker's command instead. The settle window just debounces/dedups.
            guard cmd != self.lastFired else { return }
            self.lastFired = cmd
            self.seen = nil
            fire(cmd)
        }
    }

    /// Clear dedup/debounce state — call when captions (re)start so the same
    /// command can be issued again in a fresh session.
    func reset() {
        pending?.cancel(); pending = nil
        seen = nil; lastFired = nil
    }
}

/// Captures the command a user speaks AFTER the wake acknowledgement ("Yes?"),
/// reading it straight from the live caption transcript. Debounces the latest
/// spoken line so a mid-sentence pause doesn't fire a half-command, then delivers
/// it once it settles. Separate from CaptionCommandRouter: there's no wake phrase
/// to find here — the next thing said IS the command.
@MainActor
final class PendingCommandCapture {
    private var pending: Task<Void, Never>?

    func capture(_ line: String, settle: TimeInterval = 1.4, fire: @escaping (String) -> Void) {
        let cmd = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            guard self != nil, !Task.isCancelled else { return }
            fire(cmd)
        }
    }

    func cancel() { pending?.cancel(); pending = nil }
}

struct ContentView: View {
    @State private var store = AgentStore()
    @State private var speaker = Speaker()
    @State private var vision = AnthropicVisionClient()
    @State private var glasses = StreamSessionViewModel(wearables: Wearables.shared)
    @State private var captioner = SpeechCaptioner()
    @State private var nav = NavigationManager()
    #if canImport(MWDATDisplay)
    @State private var displayManager = GlassesDisplayManager()
    #endif
    @State private var wearables = WearablesViewModel(wearables: Wearables.shared)
    @State private var captionRouter = CaptionRouter()
    @State private var captionTone: Tone = .neutral          // estimated tone hint for the latest caption
    @State private var lastTonedUtterance = ""                // dedupe Deepgram sentiment calls per line
    @AppStorage("wakeWordEnabled") private var wakeWordEnabled = false
    @State private var wakeListener = WakeWordListener()
    @AppStorage("pinchToTalkEnabled") private var pinchToTalkEnabled = false
    @State private var pinchToTalk = PinchToTalk()
    @State private var pinchLoopTask: Task<Void, Never>?
    @AppStorage("captionCommandsEnabled") private var captionCommandsEnabled = false   // always-on captions + inline "Glasses" commands
    @AppStorage("toneEmotionEnabled") private var toneEmotionEnabled = false           // tone/emotion pill on captions (Deepgram-refined)
    @AppStorage("speechEnabled") private var speechEnabled = true                      // text-to-speech: whether the app speaks replies aloud
    @AppStorage("emergencyContact") private var emergencyContact = ""                  // phone number for "call for help"
    @AppStorage("emergencyContactName") private var emergencyContactName = ""          // who that number is (for spoken confirmation)
    @State private var captionCommandRouter = CaptionCommandRouter()
    @State private var captionCommandCapture = PendingCommandCapture()   // captures the command spoken after "Yes?"
    @State private var awaitingCaptionCommand = false                    // true between "Yes?" and the command, read from captions
    @State private var captionCommandTimeoutTask: Task<Void, Never>?     // gives up awaiting if no command comes
    @State private var captionsStarting = false   // true while captioner.start() is in flight (no mic yet)
    @State private var conductorTouchedCaptions = false   // a conductor tool changed caption state this turn
    @State private var conductorDidAnnounce = false        // announceMode spoke this turn → don't clobber it with the reply
    @State private var conductorShowedSign = false         // show_sign ran this turn → keep the sign on the lens; don't overwrite with the reply
    @State private var voice = VoiceCommander()
    private let voiceClient = VoiceCommandClient()
    @State private var pendingVoiceCaptionStart = false
    @State private var memory = RemoteMemoryStore()
    @State private var conductorHistory = ConductorHistory()
    @State private var conductorActive = false
    @State private var exploreMode = false                       // continuous "talk with Claude" mode
    @State private var exploreTask: Task<Void, Never>?
    @State private var exploreHistory: [VisionMessage] = []      // text-only running conversation

    @State private var selectedItem: PhotosPickerItem?
    @State private var statusText = "Tap below to hear what's in front of you."
    @State private var isWorking = false
    @State private var isLooping = false
    @State private var liveView = false
    @State private var detector = ObjectDetector()
    @State private var brailleReader = BrailleReader()
    @State private var detectObjects = false
    @State private var signReader = SignReader()
    @State private var signWriter = SignWriter()
    @State private var signVocabReader = SignVocabReader(store: SignTemplateStore())
    @State private var showSignVocab = false
    @State private var showPOV = false
    @State private var povCaption = ""
    @State private var shownSign: LensVisual? = nil   // a sign to show full-screen on the phone (show_sign tool)
    @State private var showAgents = false
    @State private var showNavigate = false
    @State private var showMonitor = false
    @State private var showTest = false
    @State private var showSettings = false
    @State private var showSign = false
    @State private var showSignWrite = false
    @State private var visionTask: Task<Void, Never>?
    @State private var objectLoopTask: Task<Void, Never>?

    private var agent: AccessibilityAgent { store.activeAgent }

    /// The big text on the phone: caption transcript / detection readout / latest
    /// status or description, with errors surfaced rather than swallowed.
    private var displayText: String {
        if agent.kind == .captions {
            if let err = captioner.errorMessage { return err }
            // During an AI turn (after your command was captured), show the exchange —
            // the echoed command, then Bob's reply — NOT the stale caption transcript,
            // so it doesn't look like it jumped back to plain captions.
            if conductorActive { return statusText }
            if captioner.isRunning || !captioner.transcript.isEmpty {
                // After "Yes?", keep the prompt on screen until the person actually
                // responds — then their own question (the live transcript) shows in its
                // place, so they can read back what was understood.
                if captioner.transcript.isEmpty {
                    return awaitingCaptionCommand ? "Yes? — go ahead, I'm listening." : "Listening…"
                }
                return captioner.transcript
            }
        }
        if detectObjects {
            if !detector.modelAvailable { return "Model error: " + String(detector.loadError.prefix(200)) }
            return detector.detections.isEmpty
                ? "Looking for objects…"
                : detector.detections.map { "\($0.label) \(Int($0.confidence * 100))%" }.joined(separator: "   ")
        }
        return statusText
    }

    /// True while the user is talking to the AI (waiting for the command after
    /// "Yes?") or the AI is handling a turn — drives the "(AI)" header + routing.
    private var aiConversationActive: Bool { awaitingCaptionCommand || conductorActive }

    private var statusHeading: String {
        if agent.kind == .captions { return aiConversationActive ? "Captions (AI)" : "Live captions" }
        if detectObjects { return "Objects ahead" }
        return "Description"
    }

    var body: some View {
        withLifecycle(withAlerts(withSheets(mainScreen)))
    }

    /// The on-screen content. Split out from the modifier groups below so the
    /// SwiftUI type-checker handles each in isolation — one huge body plus a long
    /// modifier chain trips "unable to type-check this expression in reasonable time".
    private var mainScreen: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if exploreMode { exploreBanner }

                    agentCard

                    nodeChips

                    voiceRow

                    exploreRow

                    #if !targetEnvironment(simulator)
                    connectionBar
                    if wearables.requiresFirmwareUpdate { firmwareBanner }
                    #endif

                    statusCard

                    if liveView { liveBlock }
                    if detectObjects && !detector.detections.isEmpty { detectionList }

                    if agent.kind == .vision {
                        visionActions
                    } else {
                        captionsInfo
                    }

                    signModeRow

                    signWriteRow

                    signVocabRow

                    #if canImport(MWDATDisplay)
                    glassesDisplayTester
                    #endif
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            .navigationTitle("Glasses Assist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showTest = true } label: { Image(systemName: "ladybug.fill") }
                        .accessibilityLabel("Test tools")
                }
            }
            .safeAreaInset(edge: .bottom) { primaryAction }
        }
    }

    /// Modal presentations: sheets + full-screen covers.
    private func withSheets(_ content: some View) -> some View {
        content
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showAgents) { AgentsListView(store: store, speaker: speaker) }
        .sheet(isPresented: $showTest) {
            TestView(speaker: speaker,
                     captioner: captioner,
                     glassesLinked: glasses.hasActiveDevice,
                     onSendToLens: { title, body in mirrorToLens(title, body) },
                     onSendSignToLens: { visual in mirrorVisualToLens(visual) },
                     lensStatus: { lensStatusText() })
        }
        .sheet(isPresented: $showNavigate) { NavigateView(nav: nav, speaker: speaker) }
        .sheet(isPresented: $showMonitor) {
            MonitorView(glasses: glasses, wearerName: "Wearer",
                        startCamera: { await startMonitorCamera() },
                        stopCamera: { await stopMonitorCamera() })
        }
        .fullScreenCover(isPresented: $showPOV) {
            POVView(glasses: glasses,
                    caption: povCaption,
                    isWorking: isWorking,
                    detections: detectObjects ? detector.detections : [],
                    onDescribe: { visionTask = Task { await describeForPOV() } },
                    onClose: { showPOV = false })
        }
        .fullScreenCover(isPresented: $showSign) {
            SignView(reader: signReader,
                     glasses: glasses,
                     onLens: { title, body in mirrorToLens(title, body) },
                     startStream: { await startMonitorCamera() },
                     stopStream: { await stopMonitorCamera() })
        }
        .fullScreenCover(isPresented: $showSignWrite) {
            SignWriterView(writer: signWriter,
                           onLens: { visual in mirrorVisualToLens(visual) },
                           onClearLens: { mirrorToLens("Fingerspell", " ") })
        }
        .fullScreenCover(isPresented: $showSignVocab) {
            SignVocabView(reader: signVocabReader,
                          glasses: glasses,
                          onLens: { visual in mirrorVisualToLens(visual) },
                          onClearLens: { mirrorToLens("Signs", " ") },
                          startStream: { await startMonitorCamera() },
                          stopStream: { await stopMonitorCamera() })
        }
    }

    /// Photo-pick / agent switch, error alerts, and the listening overlay.
    /// `@Bindable` gives the alerts bindings into the observable models.
    private func withAlerts(_ content: some View) -> some View {
        @Bindable var glasses = glasses
        @Bindable var wearables = wearables
        return content
        .onChange(of: selectedItem) { _, newItem in
            guard let newItem else { return }
            Task { await describeFromPhoto(newItem); selectedItem = nil }   // reset so a repeat pick re-fires
        }
        .onChange(of: agent.id) { _, _ in handleAgentSwitch() }
        .onChange(of: glasses.showError) { _, show in
            if show { speaker.speak(glasses.errorMessage) }   // speak the cause for blind users
        }
        .alert("Glasses problem", isPresented: $glasses.showError) {
            Button("OK") { glasses.dismissError() }
        } message: { Text(glasses.errorMessage) }
        .alert("Camera couldn't take a photo", isPresented: $glasses.showPhotoCaptureError) {
            Button("OK") { glasses.dismissPhotoCaptureError() }
        } message: { Text("Please try again.") }
        .alert("Connection problem", isPresented: $wearables.showError) {
            Button("OK") { wearables.dismissError() }
        } message: { Text(wearables.errorMessage) }
        .overlay {
            if voice.isListening {
                ListeningOverlay(heard: voice.heard, onCancel: { voice.cancel() })
                    .transition(.opacity)
            }
        }
        .overlay {
            if let sign = shownSign {
                SignCardView(visual: sign) { shownSign = nil }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: voice.isListening)
    }

    /// URL-open + first-appear, and keeping the hands-free features (wake / pinch /
    /// caption commands / tone) in sync with the toggles and app state.
    private func withLifecycle(_ content: some View) -> some View {
        content
        .onOpenURL { url in
            // Completes registration / permission grants from the Meta AI app.
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  comps.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
            else { return }
            Task { _ = try? await Wearables.shared.handleUrl(url) }
        }
        .onAppear {
            #if canImport(MWDATDisplay)
            displayManager.use(glasses.deviceSessionManager)   // lens shares the camera's session
            #endif
            speaker.onWillSpeak = { wakeListener.stop() }   // TTS synchronously yields the wake mic
            speaker.isEnabled = speechEnabled               // apply the saved text-to-speech setting
            if wakeWordEnabled { Task { await requestVoicePermissionsThenSync() } }
            else { syncWakeListener() }
            syncPinchLoop()
            syncCaptionCommands()
        }
        .onChange(of: wakeListenerShouldRun) { _, _ in syncWakeListener() }
        .onChange(of: wakeWordEnabled) { _, on in
            if on { Task { await requestVoicePermissionsThenSync() } }
            else { wakeListener.stop() }
        }
        .onChange(of: pinchShouldRun) { _, _ in syncPinchLoop() }
        .onChange(of: pinchToTalkEnabled) { _, on in
            if on { syncPinchLoop() }
            else {
                pinchLoopTask?.cancel(); pinchLoopTask = nil   // loop's defer stops the detector
                Task { await stopMonitorCamera() }   // release the camera if nothing else needs it
            }
        }
        .onChange(of: captionCommandsShouldRun) { _, _ in syncCaptionCommands() }
        .onChange(of: captionCommandsEnabled) { _, on in
            if on { syncCaptionCommands() }            // start captions (captioner.start requests mic/speech)
            else if captioner.isRunning { stopCaptions() }
        }
        .onChange(of: toneEmotionEnabled) { _, on in
            if !on { captionTone = .neutral; lastTonedUtterance = "" }   // clear the pill immediately
        }
        .onChange(of: speechEnabled) { _, on in speaker.isEnabled = on }   // keep TTS switch in sync
    }

    // MARK: - Header / status

    private var agentCard: some View {
        FeatureRow(icon: agent.kind == .captions ? "captions.bubble.fill" : "eye.fill",
                   title: agent.name,
                   subtitle: agent.summary,
                   tint: .indigo,
                   hint: "Switch or create assistants") {
            showAgents = true
        }
    }

    /// The active assistant's capability nodes, shown as chips so you can SEE
    /// what Claude composed. Animates when the agent (or its capabilities) change.
    @ViewBuilder private var nodeChips: some View {
        let nodes = NodeCatalog.chips(for: agent.enabledNodeIDs)
        if !nodes.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(nodes) { node in
                        HStack(spacing: 5) {
                            Image(systemName: node.symbol).font(.caption2)
                            Text(node.title).font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(node.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(node.tint)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Capabilities: " + nodes.map(\.title).joined(separator: ", "))
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: agent.enabledNodeIDs)
        }
    }

    /// Hands-free control hero: tap (or have a helper tap) and speak any command.
    /// All app settings in one place — reuses the live toggle rows so each keeps its
    /// status text. The assistant can also flip these by voice (the `change_setting` tool).
    private var settingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    wakeRow
                    pinchRow
                    captionCommandsRow
                    toneEmotionRow
                    emergencyRow
                }
                .padding()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showSettings = false }
                }
            }
        }
    }

    /// Entry to continuous "explore mode" — talk with Claude hands-free as you walk.
    private var exploreRow: some View {
        FeatureRow(icon: "sparkles",
                   title: "Explore mode",
                   subtitle: "Talk with Claude hands-free as you walk",
                   tint: .purple,
                   hint: "Starts a continuous conversation; say “normal mode” to exit") {
            enterExploreMode()
        }
    }

    /// Shown at the top while explore mode is active.
    @ViewBuilder private var exploreBanner: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.title3).foregroundStyle(.purple).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Explore mode").font(.headline)
                    Text(voice.isListening ? "Listening…" : "Talking with Claude — say “normal mode” to exit")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Exit") { exitExploreMode() }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.purple)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Explore mode active. Say normal mode, or tap Exit.")
    }

    @ViewBuilder private var voiceRow: some View {
        Button {
            if voice.isListening { voice.cancel() } else { Task { await startConductor() } }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: voice.isListening ? "waveform" : "mic.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(.white.opacity(0.22), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(voice.isListening ? "Listening…" : "Talk to your assistant")
                        .font(.headline).foregroundStyle(.white)
                    Text(voice.isListening
                         ? (voice.heard.isEmpty ? "Speak now" : voice.heard)
                         : "Describe, navigate, captions, change settings — just ask")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold)).foregroundStyle(.white.opacity(0.75))
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(Theme.brand, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .shadow(color: .indigo.opacity(0.3), radius: 8, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(voice.isListening ? "Listening. Tap to cancel." : "Voice control. Tap, then speak a command.")
        .accessibilityHint("For example: describe, identify objects, start captions, or take me to a pharmacy")
    }

    // MARK: - Hands-free wake word ("Glasses")

    @ViewBuilder private var wakeRow: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $wakeWordEnabled) {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform.badge.mic")
                            .font(.title3).foregroundStyle(.indigo)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hands-free “Glasses”").font(.headline)
                            Text(wakeStatusText)
                                .font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .tint(.indigo)
                if wakeWordEnabled {
                    Text("On-device while idle. During live captions it scans the caption text (which may use the cloud transcriber), so anyone nearby saying “Glasses” can trigger it.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if wakeWordEnabled, let err = wakeListener.lastError {
                    Text(err).font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hands-free Glasses. \(wakeWordEnabled ? "On" : "Off"). \(wakeStatusText)")
    }

    private var wakeStatusText: String {
        guard wakeWordEnabled else { return "Say “Glasses” to control the app without tapping." }
        if wakeListener.isRunning || captioner.isRunning { return "Listening for “Glasses”…" }
        return "On — resumes listening when the app is idle."
    }

    @ViewBuilder private var pinchRow: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $pinchToTalkEnabled) {
                    HStack(spacing: 12) {
                        Image(systemName: "hand.pinch.fill")
                            .font(.title3).foregroundStyle(.pink)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pinch to talk").font(.headline)
                            Text(pinchStatusText)
                                .font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .tint(.pink)
                if pinchToTalkEnabled {
                    Text("Raise your hand into the glasses' view and pinch index + thumb to start a command. Hand shapes are read on-device — no video leaves your phone — but it keeps the camera on while idle (a battery cost).")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pinch to talk. \(pinchToTalkEnabled ? "On" : "Off"). \(pinchStatusText)")
    }

    private var pinchStatusText: String {
        guard pinchToTalkEnabled else { return "Pinch index + thumb in the camera's view to talk — no tap, no wake word." }
        if pinchLoopTask != nil { return pinchToTalk.handPresent ? "Hand in view — pinch to talk." : "Watching for your pinch…" }
        return "On — resumes when the app is idle."
    }

    @ViewBuilder private var captionCommandsRow: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $captionCommandsEnabled) {
                    HStack(spacing: 12) {
                        Image(systemName: "captions.bubble")
                            .font(.title3).foregroundStyle(.teal).frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Captions + “Glasses”").font(.headline)
                            Text(captionCommandsStatusText)
                                .font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .tint(.teal)
                if captionCommandsEnabled {
                    Text("Keeps live captions on the glasses, and watches them for “Glasses …” to run a command (e.g. “Glasses, read fingerspelling”). Say the whole command in one breath so it isn't cut off. Uses the phone mic, the app must be open, and anyone nearby saying “Glasses” can trigger it.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Captions plus Glasses. \(captionCommandsEnabled ? "On" : "Off"). \(captionCommandsStatusText)")
    }

    private var captionCommandsStatusText: String {
        guard captionCommandsEnabled else { return "Keep captions on the lens and say “Glasses …” to control the app." }
        return captioner.isRunning ? "Captions on — say “Glasses …” to run a command." : "On — captions resume when idle."
    }

    /// Opt-in tone/emotion pill on captions (Deepgram-refined, on-device fallback).
    @ViewBuilder private var toneEmotionRow: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $toneEmotionEnabled) {
                    HStack(spacing: 12) {
                        Image(systemName: "face.smiling")
                            .font(.title3).foregroundStyle(.purple).frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Emotion on captions").font(.headline)
                            Text(toneEmotionEnabled
                                 ? "On — shows a tone pill (Question · Excited · Urgent · Positive · Negative)."
                                 : "Off — captions show the words only.")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .tint(.purple)
                if toneEmotionEnabled {
                    Text("Adds a best-guess tone pill next to captions, refined by Deepgram sentiment when a key is set (on-device estimate otherwise). It reads tone from the words, not the voice — a hint, not certainty.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Emotion on captions. \(toneEmotionEnabled ? "On" : "Off").")
    }

    @ViewBuilder private var emergencyRow: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "sos.circle.fill")
                        .font(.title3).foregroundStyle(.red).frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Call for help").font(.headline)
                        Text("Say “Glasses, call for help” to phone this contact hands-free.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                TextField("Contact name (e.g. Mom)", text: $emergencyContactName)
                    .textFieldStyle(.roundedBorder)
                TextField("Phone number", text: $emergencyContact)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                if !emergencyContact.isEmpty {
                    Button { callForHelp() } label: {
                        Label("Test call", systemImage: "phone.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Text("Set who to call in an emergency. Tip: a caregiver or family member — or your local emergency number if you want that.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Call for help emergency contact.")
    }

    /// The dedicated listener should run only when the wake word is on, captions
    /// aren't (that path scans the caption transcript instead), the app isn't
    /// speaking/capturing/working, and no modal that uses the mic or camera is up.
    private var wakeListenerShouldRun: Bool {
        wakeWordEnabled
            && !captioner.isRunning && !captionsStarting
            && !conductorActive && !voice.isListening
            && !isWorking && !isLooping && !detectObjects
            && !speaker.isSpeaking
            && !exploreMode
            && !anyModalUp
    }

    private var anyModalUp: Bool {
        showPOV || showSign || showSignWrite || showSignVocab || showTest || showSettings || showMonitor || showAgents || showNavigate
    }

    /// Bring the dedicated wake listener in line with `wakeListenerShouldRun`.
    private func syncWakeListener() {
        if wakeListenerShouldRun {
            if !wakeListener.isRunning { wakeListener.start { cmd in handleWake(cmd) } }
        } else if wakeListener.isRunning {
            wakeListener.stop()
        }
    }

    /// Request mic + speech permission up front, then bring the listener in line.
    /// Used both when the toggle flips on AND on a cold launch where the toggle
    /// was already persisted on (otherwise start() would just no-op on a missing
    /// grant and the feature would silently do nothing).
    private func requestVoicePermissionsThenSync() async {
        _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        _ = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        syncWakeListener()
    }

    /// A wake phrase from the DEDICATED listener (captions off — no transcript to
    /// read). Run the conductor with any command spoken in the same breath;
    /// otherwise acknowledge and listen via the one-shot recognizer.
    // MARK: - Explore mode (continuous, hands-free conversation with Claude)

    private func isExploreTrigger(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("explore mode") || l.contains("exploration mode")
            || (l.contains("explore") && l.count <= 24)
    }

    private func isExploreExit(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("normal mode") || l.contains("back to normal")
            || l.contains("exit explore") || l.contains("stop explore") || l.contains("end explore")
    }

    private var explorePrompt: String {
        """
        You are the wearer's friendly companion while they walk around wearing camera glasses; \
        they talk to you out loud and hear your reply. Each turn may include the current camera \
        frame — use it to answer about what they see. Be warm, concise, and conversational: reply \
        in 1 to 3 short spoken sentences. If they ask for something the glasses can't do, say so \
        briefly. They will say "normal mode" to leave.
        """
    }

    /// Enter the continuous conversation loop. Frees the mic (stops captions / the
    /// wake listener) so the loop owns it, then listens → asks Claude → speaks, on repeat.
    private func enterExploreMode() {
        guard !exploreMode else { return }
        exploreMode = true
        conductorTouchedCaptions = true        // keep the conductor's resume defer from fighting us
        if captioner.isRunning { stopCaptions() }
        wakeListener.stop()
        exploreHistory = []
        statusText = "Explore mode — talk to me. Say “normal mode” to exit."
        mirrorToLens("Explore mode", "Listening… say “normal mode” to exit.")
        exploreTask?.cancel()
        exploreTask = Task { await runExploreLoop() }
    }

    /// Exit triggered by the on-screen button (or leaving the screen). The loop's own
    /// tail does the spoken hand-off + resumes the wake listener.
    private func exitExploreMode() {
        guard exploreMode else { return }
        exploreMode = false
        voice.cancel()
        exploreTask?.cancel()
    }

    private func runExploreLoop() async {
        if !isDeafProfile { speaker.speak("Explore mode on. What can I help you with?") }
        while exploreMode && !Task.isCancelled {
            // Let any reply finish so we don't capture our own voice or cut it off.
            while speaker.isSpeaking && !Task.isCancelled { try? await Task.sleep(nanoseconds: 200_000_000) }
            guard exploreMode, !Task.isCancelled else { break }
            guard let heard = await voice.listenOnce(maxSeconds: 12, silence: 1.6), !heard.isEmpty else { continue }
            if isExploreExit(heard) { break }
            statusText = heard
            let jpeg = await captureFrameJPEG()        // attach what they're looking at
            var msgs = exploreHistory
            msgs.append(VisionMessage(role: .user, text: heard, imageJPEG: jpeg))
            do {
                let reply = try await vision.converse(messages: msgs, system: explorePrompt, maxTokens: 350,
                                                      modelOverride: "claude-sonnet-4-6")   // snappier than Opus for a walking chat
                // Keep history TEXT-ONLY (no image bloat across turns) and bounded.
                exploreHistory.append(VisionMessage(role: .user, text: heard))
                exploreHistory.append(VisionMessage(role: .assistant, text: reply))
                if exploreHistory.count > 12 { exploreHistory.removeFirst(exploreHistory.count - 12) }
                statusText = reply
                mirrorToLens("Explore", reply)
                if !isDeafProfile { speaker.speak(reply) }
            } catch VisionError.missingKey {
                statusText = "No API key set."
                if !isDeafProfile { speaker.speak("No A P I key is set.") }
            } catch {
                if !isDeafProfile { speaker.speak("Sorry, I didn't catch that.") }
            }
        }
        // Cleanup — runs after an exit phrase, cancellation, or the flag flipping off.
        exploreMode = false
        exploreTask = nil
        statusText = "Back to normal mode."
        mirrorToLens("Glasses Assist", "Normal mode.")
        if !isDeafProfile { speaker.speak("Back to normal mode.") }
        syncWakeListener()   // resume hands-free wake word if it was on
    }

    private func handleWake(_ command: String) {
        guard !conductorActive else { return }   // already handling a turn
        Telemetry.breadcrumb("wake word detected", category: "voice")
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if isExploreTrigger(cmd) { enterExploreMode(); return }
        Task { await startConductor(prefilled: cmd.count >= 2 ? cmd : nil) }
    }

    // MARK: - Caption "Glasses" conversation (command read from the captions)

    /// A wake phrase detected in the live CAPTION transcript. With a command in the
    /// same breath ("glasses, take a pic"), run it directly. Bare "glasses" → say
    /// "Yes?" and then read the next thing spoken straight from the captions — the
    /// mic only goes off while "Yes?" plays, so captions stay on to hear the command.
    private func handleCaptionWake(_ command: String) {
        guard !conductorActive, !awaitingCaptionCommand else { return }
        Telemetry.breadcrumb("wake word in captions", category: "voice")
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if isExploreTrigger(cmd) { enterExploreMode(); return }
        // The captions transcript is, by design, everyone in the room — so do NOT
        // auto-run arbitrary commands pulled from it. (A bystander, or a word mis-heard
        // as "glasses … open the map", was opening apps on the glasses.) Only a tiny
        // safe-verb whitelist auto-runs; anything else gets the "Yes?" confirm so the
        // wearer must restate the command on their own breath before it executes.
        let safeVerbs: Set<String> = ["stop", "stop captions", "stop captioning", "stop listening"]
        if safeVerbs.contains(cmd.lowercased()) {
            Task { await startConductor(prefilled: cmd) }   // safe verb → run immediately
        } else {
            beginCaptionConversation()                       // bare wake OR any other command → "Yes?", don't silently act
        }
    }

    /// Acknowledge a bare "glasses" with "Yes?" (mic off only while it speaks), then
    /// bring captions back so the next spoken line is captured as the command.
    private func beginCaptionConversation() {
        guard !conductorActive, !awaitingCaptionCommand else { return }
        Task {
            let wasCaptioning = captioner.isRunning
            if captioner.isRunning { stopCaptions(announce: false) }   // mic off for the spoken "Yes?"
            statusText = "Yes?"
            mirrorToLens("Glasses", "Yes?")
            await speaker.speakAndWait("Yes?")
            guard !conductorActive else { return }                     // a turn started meanwhile
            // Bring captions back and WAIT until the mic is actually live before we
            // start capturing — otherwise the start of the command is lost.
            if wasCaptioning, !captioner.isRunning { await startCaptions() }
            guard captioner.isRunning else {                            // restart failed → bail cleanly
                statusText = captioner.errorMessage ?? "Couldn't restart captions."
                return
            }
            awaitingCaptionCommand = true
            armCaptionCommandTimeout()
        }
    }

    /// (Re)arm the inactivity timeout for an awaited command — fires only after a
    /// stretch with NO caption activity, so a slow or multi-part command isn't cut
    /// off mid-capture. Re-armed on each finalized caption while awaiting.
    private func armCaptionCommandTimeout() {
        captionCommandTimeoutTask?.cancel()
        captionCommandTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard awaitingCaptionCommand, !Task.isCancelled else { return }
            awaitingCaptionCommand = false
            captionCommandCapture.cancel()
            statusText = "Listening…"
            syncCaptionCommands()   // re-arm captions if they died while awaiting
        }
    }

    /// The command spoken after "Yes?", captured from the captions. Run it.
    private func finishCaptionCommand(_ command: String) {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        awaitingCaptionCommand = false
        captionCommandTimeoutTask?.cancel(); captionCommandTimeoutTask = nil
        captionCommandCapture.cancel()
        guard !cmd.isEmpty, !conductorActive else { return }
        Task { await startConductor(prefilled: cmd) }
    }

    /// The user's spoken command, reconstructed from the (fresh, post-"Yes?")
    /// caption transcript: every line with its "Speaker N:" diarization label
    /// stripped, joined — so a multi-segment command isn't truncated to its tail.
    private func commandFromCaptions(_ transcript: String) -> String {
        transcript.split(separator: "\n").map { line -> String in
            let s = String(line)
            if let r = s.range(of: #"^Speaker \d+:\s*"#, options: .regularExpression) {
                return String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            return s.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Hands-free pinch to talk (camera gesture)

    /// The camera pinch loop runs only when enabled and the app is idle (not
    /// capturing/working/captioning/speaking, no modal up). It uses the CAMERA,
    /// not the mic, so it doesn't conflict with TTS; the spoken command is
    /// captured afterward by startConductor.
    private var pinchShouldRun: Bool {
        pinchToTalkEnabled
            && !conductorActive && !voice.isListening
            && !isWorking && !isLooping && !detectObjects
            && !captioner.isRunning && !captionsStarting
            && !speaker.isSpeaking
            && !anyModalUp
    }

    private func syncPinchLoop() {
        if pinchShouldRun {
            if pinchLoopTask == nil { pinchLoopTask = Task { await runPinchLoop() } }
        } else if let t = pinchLoopTask {
            t.cancel(); pinchLoopTask = nil   // the loop's defer stops the detector
        }
    }

    /// Watch the glasses camera ~12 fps for a deliberate pinch. The detector is
    /// token-guarded (a stale stop can't clobber a newer start), and the loop
    /// re-acquires the camera whenever it's not streaming — so another feature
    /// stopping the stream, or glasses disconnecting, self-heals instead of
    /// leaving pinch silently dead. The camera stays on while pinch is enabled and
    /// idle (released only when the feature is turned off).
    private func runPinchLoop() async {
        let token = pinchToTalk.start { handlePinch() }
        defer { pinchToTalk.stop(token) }
        while !Task.isCancelled, pinchShouldRun {
            if glasses.streamingStatus != .streaming {
                if !(await startMonitorCamera()) {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)   // backoff (e.g. glasses disconnected)
                    continue
                }
            }
            if let frame = glasses.currentVideoFrame { await pinchToTalk.process(frame) }
            try? await Task.sleep(nanoseconds: 80_000_000)   // ~12 fps
        }
    }

    private func handlePinch() {
        guard !conductorActive else { return }
        Telemetry.breadcrumb("pinch to talk", category: "voice")
        Task { await startConductor() }   // listen for the spoken command
    }

    // MARK: - Always-on captions + inline "Glasses" commands

    /// Captions should be running (for the always-on command mode) when the toggle
    /// is on and nothing else has taken over the mic/screen: not mid-command, not
    /// in a modal, not during a one-shot capture.
    private var captionCommandsShouldRun: Bool {
        captionCommandsEnabled && !conductorActive && !voice.isListening
            && !isWorking && !anyModalUp
    }

    /// Bring captions in line with `captionCommandsShouldRun` — start them when
    /// they should be on (e.g. resume after a command or after a modal closes).
    /// Never force-stops here; turning the toggle off owns stopping.
    private func syncCaptionCommands() {
        guard captionCommandsShouldRun, !captioner.isRunning, !captionsStarting else { return }
        toggleCaptions()
    }

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(statusHeading)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer(minLength: 8)
                    if showsTonePill { tonePill }
                }
                Text(displayText)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isWorking { ProgressView().padding(.top, 2) }
            }
            .animation(.easeOut(duration: 0.2), value: captionTone)
            .animation(.easeOut(duration: 0.2), value: showsTonePill)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(statusHeading). \(showsTonePill ? captionTone.spokenPrefix : "")\(displayText)")
    }

    /// Show the estimated-tone pill only for a captions agent with a non-neutral
    /// tone while captions are actively (and error-free) running. Gating on the
    /// live state — not transcript presence — so a stale pill can't linger next
    /// to an error message or a frozen transcript after any stop path (including
    /// the Test screen stopping the shared captioner directly).
    private var showsTonePill: Bool {
        agent.kind == .captions && captionTone.showsPill
            && captioner.isRunning && captioner.errorMessage == nil
    }

    /// A small colored pill hinting at the latest caption's tone (estimated
    /// on-device from the words — see `ToneClassifier`). VoiceOver reads it via
    /// the card's combined label, so it's hidden from the a11y tree here.
    private var tonePill: some View {
        Label(captionTone.label, systemImage: captionTone.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(captionTone.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(captionTone.tint.opacity(0.15), in: Capsule())
            .accessibilityHidden(true)
            .transition(.opacity)
    }

    @ViewBuilder private var liveBlock: some View {
        VStack(spacing: 8) {
            // Isolated subview: the high-rate frame updates invalidate only it,
            // not the whole ContentView body (chips, cards, feature rows, …).
            LiveFrameView(glasses: glasses) { showPOV = true }
            Button { showPOV = true } label: {
                Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityHint("Opens the live view full screen")
        }
    }

    private var detectionList: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(detector.detections) { d in
                    HStack {
                        Text(d.label).font(.subheadline)
                        Spacer()
                        Text("\(Int(d.confidence * 100))%")
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: - Connection (real device only)

    @ViewBuilder private var connectionBar: some View {
        if wearables.registrationState == .registered {
            Label("Glasses connected", systemImage: "eyeglasses")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Button {
                wearables.connectGlasses()
            } label: {
                Label(wearables.registrationState == .registering ? "Connecting…" : "Connect glasses",
                      systemImage: "eyeglasses")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(wearables.registrationState == .registering)
        }
    }

    private var firmwareBanner: some View {
        HStack {
            Label("Glasses need a firmware update", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline).foregroundStyle(.orange)
            Spacer()
            Button("Update") { Task { await wearables.openFirmwareUpdate() } }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    // MARK: - Controls

    @ViewBuilder private var visionActions: some View {
        FeatureRow(icon: liveView ? "eye.slash" : "eye",
                   title: liveView ? "Hide glasses view" : "Show glasses view",
                   subtitle: "Mirror the glasses camera here",
                   tint: .indigo,
                   hint: "Mirrors the glasses camera on this screen") {
            Task { await toggleLiveView() }
        }
        .disabled(isWorking)

        FeatureRow(icon: "viewfinder",
                   title: detectObjects ? "Stop identifying objects" : "Identify objects",
                   subtitle: "Name what's ahead, on-device",
                   tint: .teal,
                   hint: "Continuously names the main object ahead") {
            Task { await toggleObjects() }
        }
        .disabled(isWorking)

        FeatureRow(icon: "location.fill",
                   title: "Navigate to a place",
                   subtitle: "Spoken walking directions",
                   tint: .green,
                   hint: "Get step-by-step directions read aloud") {
            showNavigate = true
        }
        .disabled(isWorking)

        FeatureRow(icon: "map.fill",
                   title: "Monitor a loved one",
                   subtitle: "See the wearer on a map and their view",
                   tint: .orange,
                   hint: "Opens a live map and camera view") {
            showMonitor = true
        }

        PhotosPicker(selection: $selectedItem, matching: .images) {
            FeatureRowLabel(icon: "photo.on.rectangle",
                            title: "Describe a photo",
                            subtitle: "Pick an image from your library",
                            tint: .pink)
        }
        .disabled(isWorking)
    }

    /// Entry to the experimental fingerspelling reader (the `sign_reading` node).
    private var signModeRow: some View {
        FeatureRow(icon: "hand.raised.fill",
                   title: "Read fingerspelling",
                   subtitle: "Experimental — reads spelled letters into captions",
                   tint: .pink,
                   hint: "Reads ASL fingerspelling and shows the letters as captions on the lens") {
            showSign = true
        }
    }

    /// Entry to the experimental "Sign what I say" coach (the `sign_speaking` node):
    /// speech → fingerspelling steps the wearer can copy back to a Deaf person.
    private var signWriteRow: some View {
        FeatureRow(icon: "hand.raised.fingers.spread.fill",
                   title: "Sign what I say",
                   subtitle: "Experimental — shows how to fingerspell your words on the lens",
                   tint: .mint,
                   hint: "Listens to you and shows how to fingerspell what you said, letter by letter, on the lens") {
            showSignWrite = true
        }
    }

    /// Entry to the experimental whole-word sign recognizer (the `sign_recognition`
    /// node): teach ~10 signs once, then read someone's signing into captions.
    private var signVocabRow: some View {
        FeatureRow(icon: "hands.and.sparkles.fill",
                   title: "Read signs",
                   subtitle: "Experimental — teach 10 words, then read them into captions",
                   tint: .teal,
                   hint: "Teach the app a small set of signs, then it captions them when someone signs") {
            showSignVocab = true
        }
    }

    @ViewBuilder private var captionsInfo: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "captions.bubble.fill").font(.title3).foregroundStyle(.teal)
                    Text(captionsDestination).font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                Label("Tone is an estimate from the words — a best-guess hint, not the speaker's actual tone of voice.",
                      systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        FeatureRow(icon: "map.fill",
                   title: "Monitor a loved one",
                   subtitle: "See the wearer on a map and their view",
                   tint: .orange,
                   hint: "Opens a live map and camera view") {
            showMonitor = true
        }
    }

    private var captionsDestination: String {
        #if canImport(MWDATDisplay)
        return "Captions appear on this screen and on your glasses display."
        #else
        return "Captions appear on this screen."
        #endif
    }

    #if canImport(MWDATDisplay)
    /// A direct test of the in-lens display, independent of any agent setting,
    /// with the live connection status so we can see exactly what the lens does.
    @ViewBuilder private var glassesDisplayTester: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Glasses display")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Text(displayManager.status)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await displayManager.show(title: "Glasses Assist", body: "Glasses display test — can you see this?") }
                } label: {
                    Label("Send test text to lens", systemImage: "eyeglasses")
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    Task { await wearables.openDATGlassesAppUpdate() }
                } label: {
                    Label("Update glasses software", systemImage: "arrow.down.circle")
                }
                .buttonStyle(SecondaryButtonStyle(tint: .orange))

                Text("If the lens stays blank, the glasses need the developer display software staged. Tap “Update glasses software,” accept the prompt, then disconnect & reconnect the glasses in the Meta AI app.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    #endif

    @ViewBuilder private var primaryAction: some View {
        Group {
            if agent.kind == .captions {
                Button { toggleCaptions() } label: {
                    Text(captioner.isRunning ? "Stop captions" : "Start live captions")
                }
                .buttonStyle(PrimaryButtonStyle(fill: captioner.isRunning ? Theme.gradient(.red) : Theme.brand))
                .accessibilityHint("Transcribes nearby speech into live text")
            } else {
                Button {
                    if isLooping { isLooping = false }
                    else { visionTask = Task { await runGlasses() } }
                } label: {
                    Text(isLooping ? "Stop" : "Describe what's in front of me")
                }
                .buttonStyle(PrimaryButtonStyle(fill: isLooping ? Theme.gradient(.red) : Theme.brand))
                .disabled(isWorking && !isLooping)
                .accessibilityLabel(isLooping ? "Stop describing" : "Describe what's in front of me")
                .accessibilityHint("Captures a photo and reads a description aloud")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: - Output routing

    private func sink(for agent: AccessibilityAgent) -> OutputSink {
        switch agent.outputMode {
        case .speech: return SpeechSink(speaker: speaker)
        case .screen, .glassesDisplay: return ScreenSink()  // the lens is mirrored universally via mirrorToLens
        }
    }

    /// Mirrors a piece of content to the in-lens display when it's available
    /// (a no-op without the display module). This is the "show everything on the
    /// glasses" path — independent of any agent's output mode.
    private func mirrorToLens(_ title: String, _ body: String) {
        #if canImport(MWDATDisplay)
        Task { await displayManager.show(title: title, body: body) }
        #endif
    }

    /// Hands-free safety action: call the user's saved emergency contact. Returns a
    /// short status the assistant speaks/shows. No-op with guidance if no number is set.
    @discardableResult
    private func callForHelp() -> String {
        let number = emergencyContact.filter { $0.isNumber || $0 == "+" }
        guard !number.isEmpty else {
            return "No emergency contact is set yet — add one under Call for help in the app."
        }
        guard let url = URL(string: "tel://\(number)") else { return "That emergency number looks invalid." }
        let who = emergencyContactName.isEmpty ? "your emergency contact" : emergencyContactName
        let msg = "Calling \(who) now."
        mirrorToLens("Calling for help", msg)   // instant visual before the call UI takes over
        UIApplication.shared.open(url)
        return msg
    }

    /// Confirms a mode/assistant change on the glasses: shows "Changed to <name>"
    /// on the lens (the confirmation deaf/HoH users rely on) and speaks it for the
    /// vision profile (matching the conductor's modality convention). Used when a
    /// hands-free command switches modes, so the user knows it landed.
    ///
    /// Pass `speak: false` to make it lens-only — used when the caption mic is about
    /// to seize audio (turning captions ON), where a spoken clip would just be cut
    /// off. When it DOES speak, it flags the turn so the conductor's own final reply
    /// won't immediately clobber the "Changed to …" confirmation.
    private func announceMode(_ name: String, speak: Bool = true) {
        let msg = "Changed to \(name)"
        if speak {
            speaker.speak(msg)   // governed by the text-to-speech setting (no-op when off)
            conductorDidAnnounce = true
        }
        mirrorToLens("Mode", msg)
    }

    /// Mirrors a rich visual (text / hosted handshape image / hosted sign video) to
    /// the lens — used by the "Sign what I say" coach. No-op without the display module.
    private func mirrorVisualToLens(_ visual: LensVisual) {
        #if canImport(MWDATDisplay)
        Task { await displayManager.show(visual) }
        #endif
    }

    private func lensStatusText() -> String {
        #if canImport(MWDATDisplay)
        return displayManager.status
        #else
        return "Display module not linked"
        #endif
    }

    // MARK: - Agent switching

    private func handleAgentSwitch() {
        guard !conductorActive else { return }   // don't tear down while Bob is mid-turn (create_agent switches the agent)
        visionTask?.cancel(); visionTask = nil
        objectLoopTask?.cancel(); objectLoopTask = nil
        isWorking = false
        isLooping = false
        detectObjects = false
        detector.clear()
        if liveView { liveView = false; Task { await glasses.stopSession() } }
        stopCaptions()
        statusText = agent.kind == .captions
            ? "Tap below to start live captions."
            : "Tap below to hear what's in front of you."
        // Voice-initiated "start captions" that had to switch assistants: start
        // here, after teardown, so it can't be torn down by this same switch.
        if pendingVoiceCaptionStart {
            pendingVoiceCaptionStart = false
            if agent.kind == .captions, !captioner.isRunning { toggleCaptions() }
        }
    }

    // MARK: - Captions flow

    private func toggleCaptions() {
        if captioner.isRunning {
            stopCaptions()
            statusText = "Captions stopped."
            return
        }
        Task { await startCaptions() }
    }

    /// Starts the live captioner and wires its transcript to the lens, tone pill,
    /// and the hands-free command paths. Awaitable so a caller can wait until the
    /// mic is actually live before listening for a spoken command.
    private func startCaptions() async {
        guard !captioner.isRunning, !captionsStarting else { return }
        statusText = "Starting…"
        captionTone = .neutral   // don't show a previous session's tone on restart
        lastTonedUtterance = ""
        captionCommandRouter.reset()   // fresh session → the same command can be issued again
        wakeListener.stop()      // captions own the mic; the wake path now scans the transcript
        captionsStarting = true  // keep the wake listener off across the start() await (no mic yet)
        defer { captionsStarting = false }
        await captioner.start(onUpdate: { text, isFinal in handleCaptionUpdate(text, isFinal: isFinal) })
        if let msg = captioner.errorMessage {
            statusText = msg
        } else if captioner.isRunning {
            statusText = "Listening…"
        }
    }

    /// Routes one caption update to the lens + tone pill, and (on finalized
    /// segments) to the hands-free "Glasses" command paths.
    private func handleCaptionUpdate(_ text: String, isFinal: Bool) {
        // Mirror every update (partials included) so the lens shows live captions.
        // Tone runs on the throttled cadence only (one classification → pill + lens).
        captionRouter.route(text) { t in
            // While awaiting a command, the user is talking TO the AI — flag that in
            // the header so it reads "Captions (AI)" (overrides the tone title too).
            let aiHeader = awaitingCaptionCommand ? "Captions (AI)" : nil
            guard toneEmotionEnabled else {
                captionTone = .neutral
                mirrorToLens(aiHeader ?? "Captions", t)
                return
            }
            let utterance = ToneHeuristics.latestUtterance(t)
            let quick = ToneClassifier.classify(utterance)
            captionTone = quick
            mirrorToLens(aiHeader ?? quick.lensTitle, t)
            guard Deepgram.hasKey, !utterance.isEmpty, utterance != lastTonedUtterance else { return }
            lastTonedUtterance = utterance
            Task {
                guard let label = await DeepgramRead.sentiment(for: utterance) else {
                    Telemetry.setTag("tone.engine", "apple"); return
                }
                Telemetry.setTag("tone.engine", "deepgram")
                let refined = ToneHeuristics.classify(text: utterance, sentimentLabel: label)
                guard refined != quick else { return }
                captionTone = refined
                mirrorToLens(aiHeader ?? refined.lensTitle, t)
            }
        }
        // Hands-free, all from the caption transcript (no second mic). Only act on
        // FINALIZED segments so nothing fires half-spoken.
        guard isFinal else { return }
        if awaitingCaptionCommand {
            // We already heard "glasses" and said "Yes?" — what's spoken now IS the
            // command. Capture the WHOLE fresh transcript (handles a multi-part
            // command) and re-arm the inactivity timeout so a slow speaker isn't cut.
            captionCommandCapture.capture(commandFromCaptions(text)) { cmd in finishCaptionCommand(cmd) }
            armCaptionCommandTimeout()
        } else if captionCommandsEnabled {
            // Scan the room transcript for wake commands ONLY when the user opted into
            // captions-commands. (Enabling just the hands-free wake word uses the
            // wearer's own mic via WakeWordListener — it must not scan everyone's speech.)
            captionCommandRouter.consider(text) { cmd in handleCaptionWake(cmd) }
        }
    }

    /// Stops captions and clears any caption left on the in-lens display. Pass
    /// `announce: false` for a TRANSIENT stop (e.g. freeing the mic for a "Glasses"
    /// command turn) so it doesn't flash "Stopped." on the lens over the next card.
    private func stopCaptions(announce: Bool = true) {
        if captioner.isRunning { captioner.stop() }
        captionRouter.reset()
        captionCommandRouter.reset()
        captionCommandCapture.cancel()
        captionCommandTimeoutTask?.cancel(); captionCommandTimeoutTask = nil
        awaitingCaptionCommand = false
        captionTone = .neutral
        lastTonedUtterance = ""
        if announce { mirrorToLens("Captions", "Stopped.") }
    }

    // MARK: - Voice control (hands-free, drives any action)

    private func voiceContext() -> VoiceContext {
        VoiceContext(
            activeAssistant: agent.name,
            activeKind: agent.kind == .captions ? "captions" : "vision",
            assistantNames: store.agents.map(\.name),
            captionsRunning: captioner.isRunning,
            describing: isLooping || isWorking,
            identifyingObjects: detectObjects,
            liveViewOn: liveView)
    }

    private func runVoiceCommand() async {
        if captioner.isRunning { stopCaptions(announce: false) }   // transient — free the mic, no "Stopped." flash
        guard let transcript = await voice.listenOnce(), !transcript.isEmpty else {
            if !voice.status.isEmpty, voice.status != "Listening…" {
                statusText = voice.status
                speaker.speak(voice.status)
            }
            return
        }
        voice.status = "Working on it…"
        do {
            let cmd = try await voiceClient.interpret(transcript, context: voiceContext())
            voice.status = ""
            await execute(cmd)
        } catch VisionError.missingKey {
            statusText = "No API key set yet — add it in Secrets.swift."
            speaker.speak("No A P I key is set yet.")
        } catch {
            let msg = "Sorry, I didn't catch that. Please try again."
            statusText = msg
            speaker.speak(msg)
        }
    }

    private func execute(_ cmd: VoiceCommand) async {
        if !cmd.reply.isEmpty {
            speaker.speak(cmd.reply)
            mirrorToLens("Assistant", cmd.reply)
        }
        switch cmd.action {
        case .describe:
            guard agent.kind == .vision else { break }
            if isLooping { isLooping = false }                      // mirror the primary button's toggle
            else { visionTask?.cancel(); visionTask = Task { await runGlasses() } }
        case .stop:
            isLooping = false
            if detectObjects { await toggleObjects() }
            if captioner.isRunning { stopCaptions() }
            statusText = "Stopped."
        case .startCaptions:
            startCaptionsViaVoice()
        case .identifyObjects:
            if agent.kind == .vision, !detectObjects { await toggleObjects() }
        case .stopIdentifyObjects:
            if detectObjects { await toggleObjects() }
        case .navigate:
            guard let dest = cmd.destination, !dest.isEmpty else { break }
            showNavigate = true
            await nav.route(to: dest)
            speaker.speak(nav.steps.isEmpty ? nav.status : nav.spokenDirections)
            mirrorToLens("Directions", nav.summary.isEmpty ? nav.status : nav.summary)
        case .switchAssistant:
            if let name = cmd.assistantName,
               !name.trimmingCharacters(in: .whitespaces).isEmpty,
               let match = bestAssistant(named: name) {
                store.setActive(match)
                announceMode(match.name)
            }
        case .newAssistant:
            showAgents = true
        case .showGlassesView:
            if !liveView { await toggleLiveView() }
        case .hideGlassesView:
            if liveView { await toggleLiveView() }
        case .openMonitor:
            showMonitor = true
        case .none:
            break
        }
    }

    private func bestAssistant(named name: String) -> AccessibilityAgent? {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lower.isEmpty else { return nil }
        return store.agents.first { $0.name.lowercased() == lower }
            ?? store.agents.first { $0.name.lowercased().contains(lower) || lower.contains($0.name.lowercased()) }
    }

    /// Starts captions by voice. If the active assistant isn't a captions one,
    /// switch to a captions assistant and let handleAgentSwitch start captions
    /// after its teardown — flag-driven, so there's no timing race.
    private func startCaptionsViaVoice() {
        if agent.kind == .captions {
            if !captioner.isRunning { toggleCaptions() }
            return
        }
        guard let cap = store.agents.first(where: { $0.kind == .captions }) else { return }
        pendingVoiceCaptionStart = true
        store.setActive(cap)
    }

    // MARK: - Conductor ("Bob": a Claude tool-use loop that runs the whole app)

    private var isDeafProfile: Bool { store.activeAgent.kind == .captions }

    /// Listen for a request, then let Claude orchestrate the app via tools.
    /// `prefilled` is the command captured alongside a wake phrase ("glasses,
    /// turn on captions") — when present we skip the second listen.
    private func startConductor(prefilled: String? = nil) async {
        guard !conductorActive else { return }   // one conductor turn at a time
        // Set the latch SYNCHRONOUSLY, before any await — so two wake matches
        // arriving back-to-back (e.g. rapid caption partials) can't both pass and
        // run the command twice. MainActor serial execution makes this atomic.
        conductorActive = true
        conductorTouchedCaptions = false         // reset; tools set this if they change captions
        conductorDidAnnounce = false             // reset; announceMode sets this if a tool confirms a switch
        conductorShowedSign = false              // reset; show_sign sets this so the reply doesn't overwrite the sign on the lens
        wakeListener.stop()                      // free the mic for command capture
        let wasCaptioning = captioner.isRunning
        if captioner.isRunning { stopCaptions(announce: false) }   // transient — don't flash "Stopped." over "Yes?"
        // Single cleanup path: always clear state and resume captions a wake word
        // interrupted — UNLESS the command itself changed caption state (e.g.
        // "stop captions"), which we must not silently undo, or it switched off a
        // captions agent.
        defer {
            conductorActive = false
            voice.status = ""
            // Per request: NEVER auto-return to the home / live-captions screen after a
            // command. Don't auto-resume captions — hold Bob's answer on the status card
            // (clear the stale caption transcript so the card shows the reply, not your
            // last spoken words) until you tap "Start live captions" or speak again.
            if store.activeAgent.kind == .captions, !conductorTouchedCaptions, !anyModalUp {
                captioner.transcript = ""
            }
        }

        let transcript: String
        if let prefilled, !prefilled.isEmpty {
            transcript = prefilled
        } else {
            // Bare wake ("glasses" with no command in the same breath):
            // acknowledge with "Yes?" — on the lens for deaf/HoH and aloud for
            // everyone — then listen for the spoken command. speakAndWait lets the
            // clip finish before the mic opens so it isn't cut off.
            statusText = "Yes?"
            mirrorToLens("Glasses", "Yes?")
            await speaker.speakAndWait("Yes?")
            guard let heard = await voice.listenOnce(), !heard.isEmpty else {
                if !voice.status.isEmpty, voice.status != "Listening…" {
                    statusText = voice.status; speaker.speak(voice.status)
                }
                return
            }
            transcript = heard
        }
        // "Explore mode" → hand off to the continuous conversation loop instead of a
        // one-shot command. (enterExploreMode sets conductorTouchedCaptions so this
        // turn's defer won't fight it.)
        if isExploreTrigger(transcript) { enterExploreMode(); return }
        // Echo the captured command on the lens + screen (like a caption of the
        // request) so the user sees what was heard before Bob acts on it.
        statusText = transcript
        mirrorToLens("You said", transcript)
        voice.status = "Thinking…"
        // Acknowledge the command before acting — "Okay" lands first (it's spoken
        // while the conductor runs), so it feels like a personal assistant: wake
        // ("Yes?") → command → "Okay" → does it → result. Spoken here while speech
        // is still on, so even "turn text to speech off" gets an audible "Okay".
        speaker.speak("Okay")
        let span = Telemetry.startSpan("conductor.run", op: "ai.agent")
        Telemetry.setTag("agent.kind", isDeafProfile ? "captions" : "vision")
        Telemetry.breadcrumb("conductor handling a voice command", category: "conductor")
        defer { span.finish() }

        // Pull cross-session, semantically-relevant memories from the backend into the
        // local cache so conductorSystemPrompt() (built synchronously below) includes
        // them. No-op offline / until the memory-service is configured.
        await memory.prime(query: transcript)

        let conductor = Conductor(tools: conductorTools)
        do {
            let reply = try await conductor.run(
                transcript: transcript,
                system: conductorSystemPrompt(),
                history: conductorHistory,
                dispatch: { name, input in await dispatchTool(name, input) })
            if !reply.isEmpty {
                statusText = reply
                if !conductorShowedSign { mirrorToLens("Assistant", reply) }   // keep a just-shown sign on the lens, don't overwrite it
                // Speak the answer (descriptions, "read this braille", confirmations).
                // Governed by the text-to-speech setting (speaker.speak no-ops when
                // it's off) — NOT the deaf/vision profile — so a captions user who
                // wants spoken answers gets them. Skipped only if a tool already
                // spoke a "Changed to …" this turn.
                if !conductorDidAnnounce { speaker.speak(reply) }
            }
            memory.learn(userText: transcript, assistantText: reply)   // extract durable prefs for next time (fire-and-forget)
        } catch VisionError.missingKey {
            statusText = "No API key set yet — add it in Secrets.swift."
            speaker.speak("No A P I key is set yet.")
        } catch {
            Telemetry.capture(error, ["phase": "conductor"])
            await fallbackInterpret(transcript)   // never hard-fail voice
        }
        // Let the spoken answer FINISH before the deferred caption-resume restarts
        // the mic — otherwise beginRecording supersedes playback and the reply is
        // cut off (shown on the lens but never heard). Only matters when captions
        // will resume; no-op when TTS is off (nothing is speaking).
        if wasCaptioning { await speaker.finishSpeaking() }
    }

    /// Fallback to the simple one-shot intent parser if the conductor errors.
    private func fallbackInterpret(_ transcript: String) async {
        do {
            let cmd = try await voiceClient.interpret(transcript, context: voiceContext())
            await execute(cmd)
        } catch {
            let msg = "Sorry, I didn't catch that. Please try again."
            statusText = msg
            speaker.speak(msg)   // governed by the text-to-speech setting
        }
    }

    private func conductorSystemPrompt() -> String {
        let a = store.activeAgent
        let who = a.kind == .captions ? "captions / deaf or hard-of-hearing" : "vision / blind or low-vision"
        let modality = isDeafProfile
            ? "This user uses captions — your reply is always shown on the lens AND spoken aloud when text-to-speech is on, so write replies that read and sound natural."
            : "This user is blind or low-vision — your reply is read aloud; speak clearly."
        return """
        You are "Bob", the assistant that RUNS glasse, an accessibility app for smart camera glasses, for blind, low-vision, deaf, and hard-of-hearing people. The user talks to you; use the TOOLS to act for them, chaining several in one turn when needed. Keep replies warm and brief — usually ONE sentence. For describe_scene / read_text, relay the tool's result to the user as-is (do NOT re-summarize or pad it): the tool returns a SHORT 1–2 sentence answer by default, and a longer, more detailed one only when the user asks for it (e.g. "be descriptive", "in detail", "tell me everything") — pass that intent through in the tool's `question`.

        Active assistant: "\(a.name)" (\(who)).
        \(modality)

        What you remember about this user and their world:
        \(memory.promptBlock)

        How to act:
        - describe_scene = say what is in front of them (also "take a pic and describe it"); read_text = read/translate any text in view — signs, labels, mail, menus, even braille (pass the user's request as the question); identify_objects / stop_identify_objects = continuous on-device naming.
        - For a deaf or hard-of-hearing user: start_captions = live speech-to-text on the lens ("turn on captions", "what are they saying"); read_fingerspelling = open the Sign reader that reads a signer's spelled letters onto the lens ("read fingerspelling", "sign language mode", "read signing").
        - For a NEW situation ("I'm at a museum", "help me cook"), use create_agent to spin up a fitting specialized assistant — it becomes active immediately — then continue.
        - navigate for walking directions; switch_agent to change assistant; show_glasses_view / hide_glasses_view; open_monitor; show_sign to show the ASL sign for a word on the lens ("what's the sign for X").
        - call_for_help = phone the user's emergency contact. Use it as soon as the user asks for help or signals an emergency ("call for help", "I need help", "emergency"); don't stall or ask extra questions first.
        - remember facts the user tells you (their name, people, pets, meds, places, preferences); recall to look them up.
        - Mode and assistant switches are confirmed to the user automatically ("Changed to …") on the glasses — don't repeat that; just acknowledge briefly.
        - When you create_agent, give it the right `enabledNodeIDs` (its capabilities) from this catalog:
        \(NodeCatalog.catalogText())
        - You are an advisory aid, NOT a replacement for a cane, guide dog, or crossing signal. Never claim certainty about safety.
        """
    }

    /// Grabs one frame from the glasses (mock on simulator). Returns nil on
    /// failure. Fast path: reuse the live video frame (instant) instead of a
    /// slow photo capture; only take a high-res photo when text legibility
    /// matters (e.g. reading labels/mail).
    private func captureFrameJPEG(highRes: Bool = false) async -> Data? {
        #if targetEnvironment(simulator)
        await GlassesMock.startIfNeeded()
        #endif
        do {
            try await waitUntil(8, "glasses") { glasses.hasActiveDevice }
            try await ensureStreaming()
        } catch { return nil }

        if !highRes {
            if let frame = glasses.currentVideoFrame, let jpeg = await Self.encodeJPEG(frame) {
                return jpeg   // warm stream → instant
            }
            try? await waitUntil(3, "a frame") { glasses.currentVideoFrame != nil }
            if let frame = glasses.currentVideoFrame, let jpeg = await Self.encodeJPEG(frame) {
                return jpeg
            }
        }

        glasses.capturePhoto()
        try? await waitUntil(12, "the photo") { glasses.capturedPhoto != nil }
        if let photo = glasses.capturedPhoto, let jpeg = await Self.encodeJPEG(photo) {
            glasses.dismissPhotoPreview()
            return jpeg
        }
        // Last resort: any live frame we have.
        if let frame = glasses.currentVideoFrame { return await Self.encodeJPEG(frame) }
        return nil
    }

    /// Executes one tool call and returns a short result string. Never throws —
    /// a failing tool reports an error string so the loop keeps going.
    private func dispatchTool(_ name: String, _ input: [String: Any]) async -> String {
        Telemetry.breadcrumb("tool: \(name)", category: "conductor")
        switch name {
        case "describe_scene", "read_text":
            var q = (input["question"] as? String)
                ?? (name == "read_text"
                    ? "Read aloud any signs, labels, or text you can see."
                    : "In one or two sentences, briefly describe the most important thing in front of me.")
            guard let jpeg = await captureFrameJPEG(highRes: name == "read_text") else { return "Couldn't get an image from the glasses." }
            if name == "read_text", let img = UIImage(data: jpeg) {
                // On-device Braille FIRST (deterministic, offline, beats the VLM on
                // clean Grade-1). Confident grid → return it; low-confidence detection
                // → hand the cells to Claude as an anchor (verify + expand Grade-2);
                // nothing found → plain Claude read. No-op if the model isn't bundled.
                let b = await brailleReader.read(img)
                if b.cellCount >= 3, b.confidence >= 0.5, !b.text.isEmpty {
                    return "Braille (\(Int(b.confidence * 100))% confidence): \(b.text)"
                } else if !b.text.isEmpty {
                    q += " An on-device Braille reader detected: \"\(b.text)\". Verify it against the image, correct any errors, and expand any Grade-2 contractions; if it isn't Braille, just read the printed text."
                } else {
                    q += " If any of the text is Braille, transcribe the Braille cells to plain text and say it's Braille; best-effort — admit if the dots are unclear rather than guessing."
                }
            }
            do { return try await vision.ask(q, imageData: jpeg, agent: store.activeAgent) }
            catch VisionError.missingKey { return "No API key is set." }
            catch { return "Vision failed." }
        case "start_captions":
            conductorTouchedCaptions = true   // don't let the resume defer fight this
            announceMode("Captions", speak: false)   // caption mic is about to seize audio; lens-only
            startCaptionsViaVoice(); return "Live captions started."
        case "read_fingerspelling":
            // Opening Sign mode is a modal; mark captions as conductor-touched so
            // the resume defer doesn't fight it. Captions resume when the modal
            // closes (onChange(anyModalUp) → syncCaptionCommands).
            conductorTouchedCaptions = true
            announceMode("Sign language")
            showSign = true
            return "Opened the fingerspelling reader."
        case "stop":
            isLooping = false
            if detectObjects { await toggleObjects() }
            if captioner.isRunning { conductorTouchedCaptions = true; stopCaptions() }
            statusText = "Stopped."
            return "Stopped."
        case "identify_objects":
            if agent.kind == .vision, !detectObjects { await toggleObjects() }
            return detector.topLabel.isEmpty ? "Identifying objects." : "Ahead: \(detector.topLabel)."
        case "stop_identify_objects":
            if detectObjects { await toggleObjects() }
            return "Stopped identifying objects."
        case "navigate":
            guard let dest = input["destination"] as? String, !dest.isEmpty else { return "No destination given." }
            showNavigate = true
            await nav.route(to: dest)
            return nav.steps.isEmpty ? (nav.status.isEmpty ? "No route found." : nav.status) : nav.summary
        case "call_for_help":
            return callForHelp()
        case "switch_agent":
            guard let nm = input["name"] as? String, let match = bestAssistant(named: nm) else { return "No matching assistant." }
            store.setActive(match)
            announceMode(match.name)
            return "Switched to \(match.name)."
        case "create_agent":
            guard let data = try? JSONSerialization.data(withJSONObject: input),
                  let draft = try? JSONDecoder().decode(AgentDraft.self, from: data) else {
                Telemetry.captureMessage("create_agent: failed to decode draft", level: .warning)
                return "Couldn't build that assistant."
            }
            store.add(draft.makeAgent(), activate: true)
            return "Created and switched to \(draft.name)."
        case "show_glasses_view":
            if !liveView { await toggleLiveView() }
            return "Showing the glasses view."
        case "hide_glasses_view":
            if liveView { await toggleLiveView() }
            return "Hid the glasses view."
        case "open_monitor":
            showMonitor = true
            return "Opened the map."
        case "show_on_lens":
            mirrorToLens(input["title"] as? String ?? "Glasses Assist", input["body"] as? String ?? "")
            return "Shown on the lens."
        case "show_sign":
            let word = (input["word"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { return "Which sign do you want to see?" }
            let visual = SignAssets.wordVisual(for: word)   // hosted clip > image > how-to text
            shownSign = visual          // show it on the PHONE too (the lens is hardware-gated)
            mirrorVisualToLens(visual)
            conductorShowedSign = true  // keep the sign on the lens — don't let the reply overwrite it
            switch visual {
            case .image, .video:
                return "Showing the sign for \(word) on your glasses."
            case .text(_, let body):
                return "I don't have a picture of the \(word) sign yet — here's how to make it: \(body)"
            }
        case "remember":
            memory.remember(category: input["category"] as? String ?? "fact", text: input["text"] as? String ?? "")
            return "Remembered."
        case "recall":
            let notes = memory.recall(matching: input["query"] as? String ?? "")
            return notes.isEmpty ? "Nothing remembered about that." : notes.map(\.text).joined(separator: "; ")
        case "change_setting":
            guard let setting = input["setting"] as? String, let on = input["on"] as? Bool else { return "Which setting, on or off?" }
            let pretty: String
            switch setting {
            case "emotion":           toneEmotionEnabled = on; pretty = "emotion on captions"
            case "wake_word":         wakeWordEnabled = on; pretty = "hands-free Glasses"
            case "captions_commands": captionCommandsEnabled = on; pretty = "captions with commands"
            case "pinch_to_talk":     pinchToTalkEnabled = on; pretty = "pinch to talk"
            case "speech":            speechEnabled = on; speaker.isEnabled = on; pretty = "text to speech"
            default: return "I don't have a setting called \(setting)."
            }
            return "\(on ? "Turned on" : "Turned off") \(pretty)."
        default:
            return "Unknown tool: \(name)."
        }
    }

    private var conductorTools: [ConductorTool] {
        let empty: [String: Any] = ["type": "object", "properties": [String: Any]()]
        func obj(_ props: [String: Any], required: [String]) -> [String: Any] {
            ["type": "object", "additionalProperties": false, "properties": props, "required": required]
        }
        let agentDraftSchema = obj([
            "name": ["type": "string"],
            "summary": ["type": "string"],
            "kind": ["type": "string", "enum": ["vision", "captions"]],
            "outputMode": ["type": "string", "enum": ["speech", "screen", "glassesDisplay"]],
            "instructions": ["type": "string"],
            "verbosity": ["type": "string", "enum": ["brief", "normal", "detailed"]],
            "captureMode": ["type": "string", "enum": ["onDemand", "periodic"]],
            "periodSeconds": ["type": "integer"],
            "enabledNodeIDs": ["type": "array", "items": ["type": "string", "enum": NodeCatalog.ids]],
        ], required: ["name", "summary", "kind", "outputMode", "instructions", "verbosity", "captureMode", "periodSeconds", "enabledNodeIDs"])

        return [
            ConductorTool(name: "describe_scene",
                          description: "Describe what is in front of the user. Returns a brief 1–2 sentence answer by DEFAULT (omit 'question'). If the user wants more (\"be descriptive\", \"in detail\", \"tell me everything\"), pass 'question' asking for a detailed description. Also use 'question' for anything specific (\"what color is the door?\").",
                          inputSchema: ["type": "object", "properties": ["question": ["type": "string"]]]),
            ConductorTool(name: "read_text", description: "Read aloud any text the camera sees — signs, labels, menus, mail, printed text, OR Braille (transcribes the Braille dots to plain text). Use this for \"what does this say\".", inputSchema: empty),
            ConductorTool(name: "start_captions", description: "Start live speech-to-text captions for a deaf or hard-of-hearing user.", inputSchema: empty),
            ConductorTool(name: "read_fingerspelling", description: "Open Sign mode — the on-device fingerspelling reader that reads a signer's spelled letters onto the lens. Use for requests like 'read fingerspelling', 'sign language mode', or 'read signing'.", inputSchema: empty),
            ConductorTool(name: "stop", description: "Stop whatever is currently running.", inputSchema: empty),
            ConductorTool(name: "identify_objects", description: "Continuously name the main object ahead, on-device.", inputSchema: empty),
            ConductorTool(name: "stop_identify_objects", description: "Stop naming objects.", inputSchema: empty),
            ConductorTool(name: "navigate", description: "Walking directions to a place.",
                          inputSchema: obj(["destination": ["type": "string"]], required: ["destination"])),
            ConductorTool(name: "call_for_help", description: "Call the user's saved emergency contact. Use when the user clearly asks for help, says it's an emergency, or asks to call for help / call their contact. Do not use casually.", inputSchema: empty),
            ConductorTool(name: "switch_agent", description: "Switch to one of the user's saved assistants by name.",
                          inputSchema: obj(["name": ["type": "string"]], required: ["name"])),
            ConductorTool(name: "create_agent", description: "Create AND activate a new specialized accessibility assistant tailored to the current situation.",
                          inputSchema: agentDraftSchema),
            ConductorTool(name: "show_glasses_view", description: "Mirror the glasses camera on the phone.", inputSchema: empty),
            ConductorTool(name: "hide_glasses_view", description: "Stop mirroring the glasses camera.", inputSchema: empty),
            ConductorTool(name: "open_monitor", description: "Open the map that shows the wearer's location and view.", inputSchema: empty),
            ConductorTool(name: "show_on_lens", description: "Show a short titled card on the in-lens display.",
                          inputSchema: obj(["title": ["type": "string"], "body": ["type": "string"]], required: ["title", "body"])),
            ConductorTool(name: "show_sign", description: "Show the ASL sign for a WORD on the glasses lens (a picture if we have one, else a how-to). Use for \"what's the sign for X\" / \"show me the sign for X\".",
                          inputSchema: obj(["word": ["type": "string"]], required: ["word"])),
            ConductorTool(name: "remember", description: "Save a fact about the user or their world (person, object, place, med, preference, routine).",
                          inputSchema: obj(["category": ["type": "string"], "text": ["type": "string"]], required: ["category", "text"])),
            ConductorTool(name: "recall", description: "Look up remembered facts matching a query.",
                          inputSchema: obj(["query": ["type": "string"]], required: ["query"])),
            ConductorTool(name: "change_setting",
                          description: "Turn an app setting on or off by voice. Settings: 'speech' (text-to-speech — whether the app talks/speaks replies aloud; use for 'turn text to speech off/on', 'stop talking', 'be quiet', 'mute', 'speak to me again'), 'emotion' (tone/emotion pill on captions), 'wake_word' (hands-free 'Glasses'), 'captions_commands' (always-on captions that also listen for 'Glasses' commands), 'pinch_to_talk' (pinch gesture to talk).",
                          inputSchema: obj(["setting": ["type": "string", "enum": ["speech", "emotion", "wake_word", "captions_commands", "pinch_to_talk"]],
                                            "on": ["type": "boolean"]], required: ["setting", "on"])),
        ]
    }

    // MARK: - Live view (glasses POV on the phone)

    private func toggleLiveView() async {
        if liveView {
            liveView = false
            detectObjects = false
            objectLoopTask?.cancel(); objectLoopTask = nil
            detector.clear()
            if !isLooping { await glasses.stopSession() }
            statusText = "Tap below to hear what's in front of you."
            return
        }
        statusText = "Starting glasses view…"
        do {
            #if targetEnvironment(simulator)
            await GlassesMock.startIfNeeded()
            #endif
            try await waitUntil(8, "glasses") { glasses.hasActiveDevice }
            try await ensureStreaming()
            liveView = true
            statusText = "Live view from your glasses."
        } catch {
            statusText = "Couldn't start the glasses view. \(error.localizedDescription)"
        }
    }

    // MARK: - On-device object detection

    private func toggleObjects() async {
        if detectObjects {
            detectObjects = false
            objectLoopTask?.cancel()
            await objectLoopTask?.value
            objectLoopTask = nil
            detector.clear()
            return
        }
        objectLoopTask?.cancel()
        await objectLoopTask?.value
        objectLoopTask = nil
        detectObjects = true
        if !liveView { await toggleLiveView() }   // start the stream + preview
        guard liveView else {                       // stream failed to start
            detectObjects = false
            detector.clear()
            return                                   // keep toggleLiveView's error statusText
        }
        objectLoopTask = Task { await runObjectLoop() }
    }

    /// Continuously segments the live frames on-device and announces the main
    /// thing ahead in one word — at most once every 5 seconds, only when it
    /// changes. Inference runs off the main actor (see ObjectDetector.process).
    private func runObjectLoop() async {
        var lastSpoken = ""
        var lastSpokenAt = Date.distantPast
        while detectObjects && !Task.isCancelled {
            if let frame = glasses.currentVideoFrame {
                await detector.process(frame)
                let word = detector.topLabel
                let now = Date()
                if !word.isEmpty, word != lastSpoken, now.timeIntervalSince(lastSpokenAt) >= 5 {
                    lastSpoken = word
                    lastSpokenAt = now
                    speaker.speak(word)
                    mirrorToLens("Ahead", word)
                }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }

    /// Describe from within the full-screen POV (keeps the live stream running).
    private func describeForPOV() async {
        let agent = store.activeAgent
        isWorking = true
        defer { isWorking = false }
        do {
            try await ensureStreaming()
            glasses.capturePhoto()
            try await waitUntil(12, "the photo") { glasses.capturedPhoto != nil }
            guard let photo = glasses.capturedPhoto,
                  let jpeg = await Self.encodeJPEG(photo) else {
                glasses.dismissPhotoPreview()
                povCaption = "No photo came back from the glasses."
                return
            }
            glasses.dismissPhotoPreview()
            let description = try await vision.describe(imageData: jpeg, agent: agent)
            povCaption = description
            guard store.activeAgent.id == agent.id else { return }
            statusText = description
            sink(for: agent).deliver(description)
            mirrorToLens("What's ahead", description)
        } catch is CancellationError {
            // POV re-described or agent switched — leave state untouched.
        } catch VisionError.missingKey {
            povCaption = "No API key set yet — add it in Secrets.swift."
            speaker.speak("No A P I key is set yet.")
        } catch VisionError.timedOut {
            povCaption = "That took too long. Please try again."
            speaker.speak("That took too long, please try again.")
        } catch {
            povCaption = "Couldn't describe that. \(error.localizedDescription)"
            speaker.speak("Sorry, I couldn't describe that.")
        }
    }

    // MARK: - Glasses (vision) flow

    private func runGlasses() async {
        let agent = store.activeAgent
        isWorking = true
        statusText = "Connecting to glasses…"
        speaker.speak("Looking")

        do {
            #if targetEnvironment(simulator)
            await GlassesMock.startIfNeeded()
            #endif
            try await waitUntil(8, "glasses") { glasses.hasActiveDevice }

            if agent.captureMode == .periodic {
                isLooping = true
                isWorking = false
                while isLooping && store.activeAgent.id == agent.id && !Task.isCancelled {
                    try await captureAndDescribe(agent: store.activeAgent)
                    let until = Date().addingTimeInterval(Double(store.activeAgent.periodSeconds))
                    while isLooping && Date() < until && !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 200_000_000)
                    }
                }
                statusText = "Stopped."
            } else {
                try await captureAndDescribe(agent: agent)
            }

            isLooping = false
            isWorking = false
            if !liveView { await glasses.stopSession() }   // keep streaming if live view is on
        } catch VisionError.missingKey {
            isLooping = false; isWorking = false
            statusText = "No API key set yet — add it in Secrets.swift."
            speaker.speak("No A P I key is set yet.")
            if !liveView { await glasses.stopSession() }
        } catch VisionError.timedOut {
            isLooping = false; isWorking = false
            statusText = "That took too long. Please try again."
            speaker.speak("That took too long, please try again.")
            if !liveView { await glasses.stopSession() }
        } catch is CancellationError {
            // Agent switched mid-flight (handleAgentSwitch already set a clean
            // status) — stay silent, don't report a false error.
            isLooping = false; isWorking = false
            if !liveView { await glasses.stopSession() }
        } catch {
            isLooping = false; isWorking = false
            statusText = "Couldn't get an image from the glasses. \(error.localizedDescription)"
            if !glasses.showError {   // a glasses error is already spoken via onChange/alert
                speaker.speak("Sorry, I couldn't get an image from the glasses.")
            }
            if !liveView { await glasses.stopSession() }
        }
    }

    private func captureAndDescribe(agent: AccessibilityAgent) async throws {
        try await ensureStreaming()
        glasses.capturePhoto()
        try await waitUntil(12, "the photo") { glasses.capturedPhoto != nil }
        guard let photo = glasses.capturedPhoto,
              let jpeg = await Self.encodeJPEG(photo) else {
            glasses.dismissPhotoPreview()
            throw SimpleError("No photo came back from the glasses.")
        }
        glasses.dismissPhotoPreview()
        statusText = "Looking…"
        let description = try await vision.describe(imageData: jpeg, agent: agent)
        guard store.activeAgent.id == agent.id else { return }   // agent switched mid-flight
        statusText = description
        sink(for: agent).deliver(description)
        mirrorToLens("What's ahead", description)
    }

    private func ensureStreaming() async throws {
        if glasses.streamingStatus == .streaming { return }
        let ok = await glasses.handleStartStreaming()
        guard ok else {
            throw SimpleError(glasses.showError ? glasses.errorMessage : "Couldn't start the glasses camera.")
        }
        try await waitUntil(20, "the camera") { glasses.streamingStatus == .streaming }
    }

    // MARK: - Monitor camera (shared stream, reused by the map screen)

    private func startMonitorCamera() async -> Bool {
        #if targetEnvironment(simulator)
        await GlassesMock.startIfNeeded()
        #endif
        do {
            try await waitUntil(8, "glasses") { glasses.hasActiveDevice }
            try await ensureStreaming()
            return true
        } catch {
            return false
        }
    }

    private func stopMonitorCamera() async {
        // Only stop if nothing else on the main screen is using the stream.
        if !liveView && !isLooping && !detectObjects { await glasses.stopSession() }
    }

    // MARK: - Photo-library flow

    private func describeFromPhoto(_ item: PhotosPickerItem) async {
        let agent = store.activeAgent
        isWorking = true
        statusText = "Looking…"
        speaker.speak("Looking")
        defer { isWorking = false }

        do {
            guard let raw = try await item.loadTransferable(type: Data.self),
                  // Decode + resize + re-encode off the main actor so picking a
                  // large photo doesn't hitch the UI thread (raw/result are Data).
                  let jpeg = await Task.detached(priority: .userInitiated) { Self.jpegData(from: raw) }.value else {
                throw SimpleError("Couldn't read that photo.")
            }
            let description = try await vision.describe(imageData: jpeg, agent: agent)
            guard store.activeAgent.id == agent.id else { return }   // agent switched mid-request
            statusText = description
            sink(for: agent).deliver(description)
            mirrorToLens("Photo", description)
        } catch VisionError.missingKey {
            statusText = "No API key set yet — add it in Secrets.swift."
            speaker.speak("No A P I key is set yet.")
        } catch VisionError.timedOut {
            statusText = "That took too long. Please try again."
            speaker.speak("That took too long, please try again.")
        } catch {
            statusText = "Something went wrong. \(error.localizedDescription)"
            speaker.speak("Sorry, something went wrong.")
        }
    }

    // MARK: - Helpers

    private func waitUntil(_ timeout: TimeInterval, _ what: String,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw SimpleError("Timed out waiting for \(what).") }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    nonisolated static func jpegData(from data: Data, maxDimension: CGFloat = 1024) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxDimension / longest)
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }

    /// JPEG-encodes a captured frame/photo off the main actor. A `nonisolated`
    /// async function runs on the global executor (SE-0338), so the CPU-heavy
    /// encode doesn't hitch the UI thread right before a vision request.
    nonisolated static func encodeJPEG(_ image: UIImage, quality: CGFloat = 0.8) async -> Data? {
        image.jpegData(compressionQuality: quality)
    }
}

/// Shows the glasses' live camera frame. Kept as its own view so the high-rate
/// `currentVideoFrame` updates invalidate only this subview instead of the whole
/// ContentView body.
private struct LiveFrameView: View {
    let glasses: StreamSessionViewModel
    let onTap: () -> Void

    var body: some View {
        if let frame = glasses.currentVideoFrame {
            Image(uiImage: frame)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
                .accessibilityLabel("Live view from the glasses camera")
                .onTapGesture(perform: onTap)
        } else {
            ProgressView("Starting glasses view…").frame(height: 160)
        }
    }
}

/// Full-screen display of one ASL sign on the PHONE (the lens is hardware-gated, so the
/// conductor's `show_sign` surfaces it here too). Hosted handshape image via AsyncImage,
/// or the how-to text when there's no picture. Tap anywhere or "Done" to dismiss.
private struct SignCardView: View {
    let visual: LensVisual
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 20) {
                switch visual {
                case .image(let title, let uri, let caption):
                    Text(title).font(.title2.weight(.bold)).foregroundStyle(.white)
                    AsyncImage(url: URL(string: uri)) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFit()
                        case .failure: Text("Couldn't load the sign image.").foregroundStyle(.white.opacity(0.8))
                        default: ProgressView().tint(.white)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: 380)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    Text(caption).font(.body).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                case .video(let title, _, let caption):
                    Text(title).font(.title2.weight(.bold)).foregroundStyle(.white)
                    Text(caption).font(.title3).foregroundStyle(.white).multilineTextAlignment(.center)
                case .text(let title, let body):
                    Text(title).font(.title2.weight(.bold)).foregroundStyle(.white)
                    Text(body).font(.title3).foregroundStyle(.white).multilineTextAlignment(.center)
                }
                Button("Done", action: onClose)
                    .font(.headline).foregroundStyle(.black)
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .background(.white, in: Capsule())
                    .padding(.top, 8)
            }
            .padding(28)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .accessibilityAddTraits(.isModal)
    }
}

struct SimpleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

#Preview {
    ContentView()
}
