# glasse — Agent Guidelines

glasse is a SwiftUI iOS accessibility app for Meta Ray-Ban Display smart glasses,
for blind, low-vision, deaf, and hard-of-hearing users. Claude is the "brain" (a
tool-use conductor named "Bob"); the glasses are the camera / mic / speaker /
lens; the iPhone runs everything.

## Read before starting work

These docs hold context that is **not** obvious from the code. Read the relevant
ones before making changes:

- **[PROJECT_STATUS.md](PROJECT_STATUS.md)** — what's built, what's queued, and
  the hackathon prize tracks (Anthropic / Deepgram / Sentry). **Start here.**
- **[ACCESSIBILITY_ML_RESEARCH.md](ACCESSIBILITY_ML_RESEARCH.md)** — on-device ML
  options per disability + roadmap.
- **[SIGN_MODE.md](SIGN_MODE.md)** — fingerspelling → captions design + plan.
- **[DISPLAY_SETUP.md](DISPLAY_SETUP.md)** — how the in-lens display was enabled.
- **[SENTRY.md](SENTRY.md)** — telemetry / observability wiring + activation steps.

## Conventions

- **Secrets:** API keys live in `glasse/Secrets.swift` (gitignored). Never commit
  keys or paste them where they could be committed.
- **Large model:** `glasse/ISANet.mlmodel` is gitignored (download separately).
- **Dependency:** the app uses the `meta-wearables-dat-ios` Swift Package
  (`MWDATCore` / `MWDATCamera` / `MWDATDisplay` / `MWDATMockDevice`).
- **Concurrency:** Swift 5 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION =
  MainActor` — keep CPU-heavy work (image encode/resize, ML inference) off the
  main actor.
- Core ML inference runs on a real device only (not the iOS Simulator).
