# glasse — Project Status & Plan

_Accessibility companion for Meta Ray-Ban Display glasses. Claude is the brain (a tool-use "conductor"); the glasses are the camera / mic / speaker / lens; the iPhone runs everything._

Last updated: 2026-06-20 (capability-node system landed).

---

## ✅ Built (in the app, compiles on simulator + device)

**Core glasses pipeline**
- Glasses camera → **Claude vision** scene description, spoken aloud (`AnthropicVisionClient`, now with custom-question + multi-turn `ask`/`converse`).
- **On-device object detection** (ISANet / ADE20K, Core ML, off-main) — names what's ahead.
- **Live captions** for deaf/HoH (`SpeechCaptioner`).
- **Tone/emotion captions** — live captions carry a best-guess **tone pill** (Question · Excited · Urgent · Positive · Negative) so Deaf/HoH readers get prosody, not just words. On-device via Apple **NaturalLanguage** sentiment + punctuation/keyword cues (`ToneClassifier` / `ToneHeuristics`; pure logic unit-tested 35/35 with `swiftc`, incl. adversarial-review regressions); shown on the captions card and mirrored to the lens; honestly framed as an estimate from the words. On-device NL gives the **instant** tone + fallback; **Deepgram's Read (text-intelligence) sentiment refines the emotion on each finalized line** (`DeepgramRead.sentiment` → `ToneHeuristics.classify(text:sentimentLabel:)`, `tone.engine` tagged in Sentry), since Deepgram sentiment runs on text, not the live STT socket.
- **Navigation** — spoken MapKit walking directions (`NavigationManager`).
- **In-lens display** — renders cards/text to the glasses lens (`GlassesDisplay`) — **working on device**.
- **Mock device** for the Simulator (`GlassesMock`).

**Accessibility agents**
- Agent model + local-JSON store + Claude **agent builder** (structured output) + agents list + switching + periodic capture.
- Output routing: speech / phone screen (VoiceOver) / in-lens (`OutputSink`, `mirrorToLens`).
- **Capability nodes** — capabilities are data (`enabledNodeIDs`); one `NodeCatalog` is the single source feeding the builder *and* conductor `create_agent` schemas; **node chips** on the main screen show what Claude composed; modality-safety (a Deaf user can't get a speech-only agent); tolerant legacy migration that can't wipe saved agents.
- **Fingerspelling reader (Sign mode)** — Apple Vision hand-pose (on-device) → geometric letter classifier (`SignClassifier`, unit-tested 11/11) → debounced word assembly (`SignReader`) → full-screen UI with a confidence chip, mirrored to the lens (`SignView`). Experimental, honest framing; the `sign_reading` node now has a real backend.

**Claude conductor ("Bob")**
- Voice → Claude **tool-use loop** that operates the whole app (`Conductor`, `VoiceCommander`): describe, read text, captions, objects, navigate, switch/**create** agents, show-on-lens, **remember/recall**.
- **Agent factory** (Claude writes a new agent live) + **MemoryStore** (on-device).

**Voice engine (Deepgram + Apple fallback)**
- **TTS:** Deepgram **Aura** (validated: returns real audio) → Apple fallback.
- **STT:** Deepgram **Nova-3 streaming + speaker diarization** for captions → Apple fallback. (Conductor command capture stays on Apple on-device for speed.)

**Quality / polish**
- Onboarding intro, design system (`Theme`), redesigned main screen, alerts + spoken errors.
- **55 bugs fixed** across three audits; one headline perf win applied (describe reuses the live frame → near-instant).

---

## 🔧 Next on the node system (optional)

- **`sign_to_captions`** — the experimental fingerspelling reader is registered as a node but has **no backend yet**; build it as Sign mode (#31).
- **Tap-to-toggle chips** — chips are display-only today; could make a tap toggle a capability live.
- Reviewed adversarially (5 dimensions); 2 confirmed issues found + fixed (decode-path modality coercion; Test-screen label sync).

---

## 📋 Queued (not started)

- **Turn Bob into a real assistant via MCP** — Claude's MCP connector lets Bob call external services (calendar, messaging, smart home, transit): "text Mom I'm five minutes away," "what's my next appointment," "turn on the kitchen lights." The leap from describing the world to acting in it. Hook: add `mcp_servers` + the `mcp-client` beta header to the conductor request body (`Conductor.swift`); new dispatch paths in `dispatchTool` (`ContentView.swift`). Route via the AWS/GCP/Azure backend, not an embedded key.
- **Self-improving memory — Bob learns from past interactions** — beyond the current `remember`/`recall` facts (`MemoryStore.swift`), have Bob *learn preferences and patterns* and apply them automatically: e.g. infer "this user likes detailed descriptions" / "prefers short replies" / "usually asks to read menus at restaurants" from past turns, persist it, and fold it into `conductorSystemPrompt()` so behavior adapts over time without being told each session. Start by auto-capturing a small set of preference signals (verbosity, recurring requests, corrections) after each conductor turn, then summarize them into the prompt's memory block. Bigger version: a periodic reflection pass that distills the interaction log into durable "what works for this user" notes.
- **Perf + UI audit fixes** — 24 of 25 remaining (latency wins + UI cleanup; only the live-frame fix is applied).
- **Speech-speed / clarity** control (slower, clearer voice for hard-of-hearing).
- **Sign mode** — experimental on-device *fingerspelling reader* → lens captions (researched; honest, best-effort).
- **"Voice: Deepgram / Apple" indicator** for the demo.
- **Sponsor integrations** — Anthropic + Deepgram + **Sentry all live**. Sentry: `sentry-cocoa` 8.58.3 on the `glasse` target + instrumented (`Telemetry.swift`) + DSN set in `Secrets.swift` — **verified live** (test event confirmed in the `calhacks-gi` Sentry project). See `SENTRY.md`; Redis / Arize optional.
- **Sentry enhancements** (DSN now set ✅ — these strengthen the integration; ranked by impact ÷ effort):
  - **Connect the trace** `code · S` — nest the `vision` / tool / TTS spans under `conductor.run` so one voice command = one flame-graph. Today `vision.converse` calls `startTransaction` (`Telemetry.swift:127`) → it's an orphan root transaction, not a child of `conductor.run`. Add `child` spans in `dispatchTool`; thread the parent into `AnthropicVisionClient.converse`.
  - **`reportDegradation()` helper + capture the silent STT socket drop** `code · S` — one uniform `degraded:` event at the 3 fallback sites (TTS `ContentView.swift:28`, STT-start `SpeechCaptioner.swift:69`, conductor→parser `ContentView.swift:843`), **plus** the swallowed mid-session Deepgram STT WebSocket drop (`Deepgram.swift:178`) — that's a real bug: a Deaf user's captions freeze on stale text with zero signal.
  - **Degradation dashboard + fallback-rate alert** `dashboard · M` — engine-share + degradation timeline; alert when fallbacks spike. The "pull the key → captions degrade → Sentry fires" demo beat. Export to `docs/sentry/`.
  - **`beforeSend` scrub/allowlist** `code · M` — enforce "no transcripts / frames / keys leave the device" (raw API response body currently rides in `VisionError.http`, `AnthropicVisionClient.swift:113`).
  - **Reliability trio in `Telemetry.start()`** `code · S` — Release Health (crash-free sessions), `profilesSampleRate`, App-Hang tracking. ~6 lines, no new call sites.
  - **High-signal global tags** `code · S` — `glasses.connected`, `output.mode` / profile so every issue is sliceable.
  - _Smaller, if time:_ mic/STT span, `captureFrameJPEG` warm-vs-slow sub-spans, `NavigationManager` route-failure captures, Deepgram TTS 401/429/timeout capture, anonymized install-id, `net.type` tag.
  - _Vetted & cut:_ span-lifetime rework to attach the async TTS leg (real bug, disproportionate risk for the demo); a standalone `beforeSend` unit-test target (no test target exists — demo via the 🐞 screen).
- **Rotate API keys** (Anthropic + Deepgram were pasted in chat).

---

## ⏳ Verified vs. needs-your-device
- **Verified by me:** builds (sim + device), UI renders, in-lens display works, describe works on glasses, Deepgram TTS returns real audio + STT key valid.
- **Needs a device + live mic to confirm:** the conductor's full live loop, Aura voice routing into the glasses, live diarized captions.

---

## 🏆 Hackathon prize tracks

glasse is being submitted to all three tracks below — Anthropic, Deepgram, and Sentry.

### Anthropic

_Rewards the biggest swing at a hard, meaningful problem in health, education, economic opportunity, or human capability — aspiration and effort over polish._

glasse turns Meta Ray-Ban Display glasses into an everyday accessibility aid for blind, low-vision, deaf, and hard-of-hearing users. Claude isn't one API call — it's the orchestrating brain: a Haiku tool-use loop ("Bob") runs the whole app by voice while Opus does the heavy lifting (vision, agent authoring, intent) inside the tools. It stays honest about being an advisory aid, not a cane/guide-dog replacement.

**Evidence in the code**
- **Claude as agentic tool-use conductor that runs the whole app by voice** — `Conductor.swift` `Conductor.run` + `ContentView.swift` `startConductor` / `dispatchTool` / `conductorTools` (15 tools)
- **Claude-vision scene description shaped per accessibility agent (Opus 4.8)** — `AnthropicVisionClient.swift` `converse` / `describe` / `ask`
- **Claude builds custom accessibility agents from a chat about a disability (structured outputs + adaptive thinking)** — `AgentBuilderClient.swift` `nextTurn` + `AgentBuilderView.swift`
- **Capability nodes as single source of truth — feeding the output enum, per-agent prompts, and on-screen chips** — `CapabilityNode.swift` `NodeCatalog` consumed by `AgentBuilderClient.schema` and the conductor's `agentDraftSchema` (defined in `ContentView.swift` `conductorTools`)
- **Compounding on-device memory injected into the conductor prompt ("a dog" → "Scout")** — `MemoryStore.swift` `remember` / `recall` / `promptBlock`
- **Modality-safety invariant — a deaf/captions user can never be assigned a speech-only agent** — `AccessibilityAgent.swift` `coercedOutputMode`
- **Honest hybrid: on-device segmentation for the private always-on loop** — `ObjectDetector.swift` `segment` / `analyze`

Emphasize in the demo: speak one natural request ("I'm at a museum, help me") and let Bob chain `create_agent` → `describe_scene` live — the clearest proof Claude *runs* the app.

### Deepgram

_Rewards the most creative and well-executed voice experience, judged on creativity, technical execution, and how essential voice is rather than tacked on._

For glasse, voice is the entire interface: for blind users the primary output is Deepgram Aura TTS in their ear (with Apple TTS as a fallback), and for deaf users Deepgram Nova-3 streaming STT with speaker diarization *is* the product — turning spoken conversation into labeled on-lens captions. Both are wired into the default code paths, not stubs.

**Evidence in the code**
- **Aura-2 TTS (`aura-2-thalia-en`) as the default voice-output path, Apple only as fallback** — `Deepgram.swift` `DeepgramTTS.speak` + `ContentView.swift` `Speaker.speak`
- **Nova-3 streaming STT over WebSocket with smart_format, interim_results, and diarization** — `Deepgram.swift` `DeepgramTranscriber.start(diarize:onUpdate:)`
- **Speaker diarization rendered as "Speaker N:" caption lines** — `Deepgram.swift` `DeepgramTranscriber.diarized`
- **Nova-3 as the preferred live-caption engine, Apple speech as graceful fallback** — `SpeechCaptioner.swift` `start(onUpdate:)`
- **Live PCM mic audio downsampled to 16kHz linear16 and streamed frame-by-frame** — `Deepgram.swift` `convertAndSend` / `sendPCM`
- **Audio-session arbitration so TTS playback and the caption mic never clobber each other** — `AudioCoordinator.swift` `beginPlayback` / `beginRecording`
- **Built-in A/B diagnostics (Aura vs Apple) and live engine label** — `TestView.swift` `ttsCard` / `captionsCard`

Emphasize in the demo: two people talking with Nova-3 diarization labeling "Speaker 1:" / "Speaker 2:" on the lens in real time — the most visually compelling use of Deepgram STT.

### Sentry

_Rewards strong technical execution and clear communication, with bonus points for building in observability and thinking about reliability from day one._

glasse treats reliability as a safety requirement: a blind user can't see a frozen screen and a deaf user can't hear a failed caption. Sentry is centralized behind one purpose-built wrapper and threaded through every fragile path — the Claude conductor, vision calls, and the Deepgram fallbacks — with a privacy stance that keeps camera frames and transcripts off the wire. Honest caveat: the SPM package and a real DSN still need to be added, so today the calls compile to a clean no-op (activation runbook in `SENTRY.md`).

**Evidence in the code**
- **Single dependency-optional wrapper (`#if canImport(Sentry)`-gated) — capture / breadcrumb / setTag / startSpan** — `Telemetry.swift` `enum Telemetry` + `struct TelemetrySpan`
- **Launch init with full tracing and privacy guards (attachScreenshot=false, attachViewHierarchy=false)** — `Telemetry.swift` `Telemetry.start` + `glasseApp.swift` `init`
- **"conductor.run" performance transaction with `agent.kind` tag and a breadcrumb per tool call** — `ContentView.swift` `startConductor` / `dispatchTool` + `Conductor.swift` `run`
- **"vision.converse" span plus captured handled errors for timeouts and non-200s** — `AnthropicVisionClient.swift` `converse`
- **STT/TTS engine tags and warnings on silent fallback to Apple** — `SpeechCaptioner.swift` `start` + `ContentView.swift` `Speaker.speak`
- **create_agent decode-failure surfaced as a warning event** — `ContentView.swift` `dispatchTool` (create_agent case)
- **In-app self-test UI (status row + send-test-event/error buttons)** — `TestView.swift` `sentryCard`

Emphasize in the demo: frame it as *observability of graceful degradation* — the app degrades silently (Deepgram→Apple, conductor→simple parser) and Sentry is what makes those invisible field failures visible.

## 📄 Reference docs in this repo
- `ACCESSIBILITY_ML_RESEARCH.md` — ML options per disability + roadmap.
- `DISPLAY_SETUP.md` — how the in-lens display was enabled (the verified, free-account path).
- `SIGN_MODE.md` — sign-language → captions research + the buildable plan.
- `PROJECT_STATUS.md` — this file.

## Where else to see progress
- **In-app task list** — every tracked task (this is the live checklist).
- **`/workflows`** — live progress of any running research/design/review runs.
