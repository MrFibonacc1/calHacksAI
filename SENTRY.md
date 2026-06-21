# Sentry — observability & error monitoring

glasse is wired for Sentry through one wrapper (`Telemetry.swift`). The wrapper is
`#if canImport(Sentry)`-gated, so the app builds and runs **with or without** the
Sentry package — it's a no-op until you add the package *and* set a DSN.

## Activate in 3 steps

### 1. Add the Sentry package (Xcode)
- **File → Add Package Dependencies…**
- URL: `https://github.com/getsentry/sentry-cocoa`
- Dependency rule: **Up to Next Major Version** (8.x)
- Add Package → check the **Sentry** product → add it to the **glasse** target.

### 2. Paste your DSN
- In Sentry: create/select a project (platform **Apple → iOS**) → **Settings → Client Keys (DSN)** → copy the DSN (`https://…@o…ingest.sentry.io/…`).
- Put it in `Secrets.swift`:
  ```swift
  static let sentryDSN = "https://…@o…ingest.sentry.io/…"
  ```
  (Secrets.swift is gitignored — the DSN is not a secret credential, but keep it out of git anyway.)

### 3. Verify
- Run the app → tap the **🐞** (Test screen) → **Observability (Sentry)** card → **Send test event** / **Send test error**.
- Check **Sentry → Issues** (event arrives in ~1 min) and **Performance** for the `conductor.run` transaction after a voice command.

## What's instrumented (the reliability story)

| Where | Signal |
|---|---|
| Launch (`glasseApp`) | `Telemetry.start()`; captures `Wearables.configure()` failures. |
| **Claude conductor** (`startConductor`) | `conductor.run` **performance transaction**; tag `agent.kind`; a **breadcrumb per tool call** (`dispatchTool`); captures conductor errors. |
| **Vision** (`AnthropicVisionClient`) | `vision.converse` span; captures **timeouts** and **non-200s** with status + model. |
| **Deepgram TTS** (`Speaker`) | tag `tts.engine` (deepgram/apple) + breadcrumb on **silent fallback** to Apple. |
| **Deepgram STT** (`SpeechCaptioner`) | tag `stt.engine`; **event** when Deepgram fails to start and we fall back. |
| **create_agent** | event when Claude's agent draft fails to decode. |

**Privacy:** screenshots + view hierarchy are disabled (no camera frames leave the
device), and we send operation names / timings / error metadata — never raw
transcripts or images.

## Framing for the submission
- **Reliability from day one:** glasse is an accessibility tool — a blind user can't
  see a frozen screen, a Deaf user can't hear a failed caption — so we monitor errors
  and time every Claude / Deepgram round-trip.
- **Observability of graceful degradation:** the app *degrades* silently (Deepgram→Apple,
  conductor→simple parser). Sentry makes those invisible fallbacks **visible**, so you
  know when the premium path is failing in the field.
- **Uses the Sentry API** via the official `sentry-cocoa` SDK on a free account.
