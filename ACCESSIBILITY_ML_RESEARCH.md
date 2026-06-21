# Accessibility ML Models — Options & Recommendations

**For:** glasse (iOS app paired with Meta Ray-Ban Display glasses)
**Date:** 2026-06-19

## Overview

The single fact that drives every recommendation below: **the Meta Wearables Device Access Toolkit (developer preview, Dec 2025) runs no code on the glasses.** The glasses are a camera + mic + speaker + in-lens display; frames stream to the paired iPhone at **max 720p/30fps over Bluetooth** (auto-degrading under bandwidth pressure), mic input arrives as **8 kHz beamformed mono tuned to the wearer's own voice**, and there is **no LiDAR, no ARKit, no depth sensor, and no multichannel mic array** exposed. So "on-device ML" means *on the iPhone Neural Engine*, and the right architecture is **on-device-first for the always-on/safety loop, with a frontier cloud VLM reserved for explicit, single-frame "tell me more" requests** — never a stream. glasse already has the core of this (Claude vision scene description, ISANet ADE20K segmentation in `ObjectDetector.swift`, Apple Speech captions via `SFSpeechRecognizer`, MapKit navigation, gated display path); the work ahead is filling capability gaps and hardening what exists. Note two non-technical blockers: public glasses distribution is **partner-gated until later in 2026**, and frame quality (720p BT), not model quality, is the dominant accuracy limiter for small text, partial banknotes, and Braille.

---

## Blind / low-vision

| Model / API | Framework | On-device? | License |
|---|---|---|---|
| **Depth Anything V2 Small** | Core ML (official Apple conversion) | Yes — ~31ms/frame on iPhone 12 Pro Max | **Apache-2.0 (Small only)** — Base/Large/Giant are CC-BY-NC, do not ship |
| **Apple ARKit Scene Depth** (sceneDepth / smoothedSceneDepth) | ARKit (first-party) | Yes — LiDAR iPhones, **phone rear camera only** | Apple SDK (free) |

**What it adds:** Depth Anything V2 Small gives dense *relative* monocular depth on the RGB-only glasses feed (how near/far, obstacle shape) — the best single choice for the hands-free path. ARKit Scene Depth gives *true metric* depth but only when the user points the **phone**, so offer it as a "point your phone to check" precise mode for safety-critical distance (curbs, stairs, drop-offs).

Supporting layers: a **nano object detector** (YOLO11n/YOLOv8n) names discrete hazards — but **YOLO is AGPL-3.0**, a copyleft trap for a closed-source app; use a permissive alternative or buy the Ultralytics commercial license. **Apple Vision `VNRecognizeTextRequest`** (`.fast`, on-device, free, ~18 languages) handles live scene-text reading; **`RecognizeDocumentRequest`** (iOS 26) reads structured docs (receipts, labels, mail) in order. **Apple FastVLM / SmolVLM** run conversational scene description on-device for the default "what do you see" loop, keeping the frontier cloud VLM for on-demand depth. **Microsoft BankNote-Net** (MobileNetV2 → Core ML, MIT code) identifies currency (it already backs Seeing AI). Color naming is **algorithmic, not ML** (RGB→CIELAB nearest-neighbor via CIEDE2000) — no model needed.

> **Honest caveat:** Monocular depth is *relative*, not metric. Present distance as coarse bands ("very close / close / ahead"), never exact meters, and frame everything as an **advisory assist — not a certified mobility aid or white-cane replacement** (comparable wearables report ~85–89% obstacle-avoidance success, ~1.2s warn latency).

---

## Deaf / hard-of-hearing

| Model / API | Framework | On-device? | License |
|---|---|---|---|
| **Apple SpeechAnalyzer + SpeechTranscriber** (iOS 26) | Apple Speech | Yes — long-form, no 1-min cap, runs outside app memory | Apple SDK (free) |
| **Apple SoundAnalysis** (`SNClassifySoundRequest .version1`) | Apple SoundAnalysis | Yes — 300+ classes incl. alarms, sirens, doorbells | Apple SDK (free) |

**What it adds:** SpeechAnalyzer is the best live-captioning engine if you can require iOS 26 (~2× faster than Whisper Large-v3-Turbo, comparable accuracy) — the upgrade path from the current `SFSpeechRecognizer` in `SpeechCaptioner.swift`. SoundAnalysis is the lowest-effort environmental-alert layer (alarm_clock, ambulance_siren, smoke/CO detector, doorbell) mapping straight to haptic/in-lens alerts.

Fallbacks/complements: **WhisperKit** (MIT, base/base.en) or **FluidAudio Parakeet** (no silence-hallucination, good for always-on; mind CC-BY-4.0 on the converted weights) for iOS 18-and-earlier or version-locked accuracy. Keep `SFSpeechRecognizer` only as a legacy path — it has a **1-minute session cap** and an iOS 18.0 pause bug (fixed in 18.1), so engineer session rotation. **SpeakerKit** (Pyannote v4, Core ML, ~10 MB) gives "who spoke" diarization for color-coded captions. Always gate Whisper-family models with VAD to avoid silence hallucination.

> **Honest caveats:** (1) **Speaker *direction* ("which way to look") is not feasible from the glasses** — the 5-mic array is delivered as 8 kHz beamformed mono with no DoA data; derive it from the iPhone's own mics or drop the feature. (2) The glasses' 8 kHz ambient-suppressed mono is tuned for the *wearer's* voice and degrades captioning of *other* people and external alarms — **capture from the iPhone's 48 kHz mics** for STT and sound recognition, and use the glasses primarily as the **output surface** (speakers + in-lens display).

---

## Sign-language users

| Model / API | Framework | On-device? | License |
|---|---|---|---|
| **Apple Vision `VNDetectHumanHandPoseRequest`** (extractor) | Apple Vision | Yes — 21 pts/hand, auto Neural Engine, 0 MB | Apple SDK (free) |
| **Kaggle ASL Fingerspelling 1st-place** (Squeezeformer + transformer decoder) | PyTorch/TF → Core ML | Yes — proven on-device in PopSign | Open-source (verify repo terms) |

**What it adds:** A **landmark-first, two-stage pipeline** is the only realistic on-device pattern. Stage 1 (Vision hand-pose, throttled to ~12–15 fps) turns frames into 21-point skeletons; Stage 2 (the Kaggle Squeezeformer model, consuming landmark *sequences*) recognizes **fingerspelling** — the highest-value, most-shippable target. For a later word-level feature, use a **skeleton-only transformer** (SignBart / NLA-SLR) on a *bounded* WLASL100/300 vocabulary, and switch the extractor to **MediaPipe Holistic** (Apache-2.0) for 3D + face/body landmarks. Convert via **coremltools** — note there is **no direct TFLite→Core ML path**, so convert from the source PyTorch/TF graph.

> **Honest caveats:** Scope tightly — **do NOT ship the 93% RGB+pose ensembles or I3D/Swin/VideoMAE video models** (leaderboard models, not real-time-phone models), and **do not attempt continuous/sentence-level ASL** in v1. In-the-wild fingerspelling SOTA is ~77% letter accuracy (native humans only ~86%); a first-person, partially-occluded 720p view lands below that. Add a dictionary/LM post-correction pass and a visible confidence indicator rather than promising verbatim transcription.

---

## Broader / everyone

| Model / API | Framework | On-device? | License |
|---|---|---|---|
| **ISANet ADE20K segmentation** (already bundled) | Core ML via Vision (`.cpuAndGPU`) | Yes — already running in `ObjectDetector.swift` | MIT |
| **Apple Translation framework** | Apple Translation (iOS 18+) | Yes — offline language packs | Apple SDK (free) |

**What it adds:** ISANet already powers the fast, private, offline "what's ahead / safe-to-walk" safety loop — keep it for low-latency continuous awareness (it intentionally skips the ANE because its segmentation ops fail ANE compilation; GPU is fast enough). Pair it with a true depth/obstacle signal (Depth Anything on the glasses path, or phone LiDAR) since pixel-class segmentation is coarse. Apple Translation handles offline caption/sign translation, escalating only rare languages/jargon to cloud NMT.

---

## Build next (prioritized)

1. **Harden the existing cloud vision path (security, before anything else).** `Secrets.swift` ships a live Anthropic key and `AnthropicVisionClient.swift` calls `api.anthropic.com` directly — the key is extractable from the binary. Route through a backend on **AWS / GCP / Azure**, sign a BAA, disable training/retention, and gate each cloud send behind explicit per-request consent. *Rationale: a vulnerable-user, always-on camera/mic product cannot ship an embedded key or stream non-consenting bystanders to a third party.*
2. **Migrate live captions to Apple SpeechAnalyzer (iOS 26), keep `SFSpeechRecognizer` as fallback.** *Rationale: faster, long-form (no 1-min cap), on-device, and caption quality *is* the product for HoH users.*
3. **Add the Depth Anything V2 Small + nano-detector layer to the glasses feed.** *Rationale: turns "something is near" into "a person is close, ahead-left" — the biggest jump in blind-nav usefulness on the RGB-only path.*
4. **Add an on-device VLM (FastVLM / SmolVLM) for the default "what do you see," reserving cloud Claude for "tell me more."** *Rationale: works offline, private, lower latency/battery; tune verbosity *concise* (2025 BLV research found frontier descriptions over-cautious/redundant).*
5. **Add Apple SoundAnalysis environmental alerts + a "point your phone for precise depth" ARKit mode.** *Rationale: cheap, high-value safety wins — sirens/alarms for HoH, metric curb/stair distance for blind users — both reuse Apple frameworks.*
6. **Prototype fingerspelling (Vision hand-pose + Kaggle Squeezeformer).** *Rationale: highest-value sign feature that is actually shippable on-device; defer word-level and continuous ASL.*
7. **Currency (BankNote-Net) + algorithmic color naming.** *Rationale: small, license-clean, well-proven additions once the core loops are solid. Treat Braille as experimental — no license-clean on-device drop-in exists.*

---

## On-device vs cloud

**Default to on-device** for the always-on safety/awareness loop, live captioning, scene-text OCR, and the default scene description — for latency, battery, offline use, and as the **privacy/compliance posture** (GDPR/EDPB bystander-consent scrutiny; strengthened 2025 HIPAA Security Rule if any health context). No frame leaves the device on the safety path.

**Cloud is an opt-in, single-frame escalation only** — never a stream — for richer "describe in detail / read this complex document" requests, where a frontier VLM is still materially better than any on-device model. **Cloud must be AWS, GCP, or Azure only** (per company policy; these also host Claude/Gemini/Azure OpenAI), behind your own backend (no embedded keys), under a signed BAA, with training and retention disabled and PII redaction on audio. Surface a recording indicator and a clear consent cue at the moment a frame leaves the device.

---

**Licensing landmines to track:** YOLO11/YOLOv8 = **AGPL-3.0** (needs commercial license or permissive swap); Depth Anything V2 = **Apache-2.0 Small only** (Base/Large/Giant non-commercial); Apple Depth Pro and some SegFormer/SAM checkpoints carry **research/source-available terms** — verify before shipping; FluidAudio Parakeet weights = **CC-BY-4.0** (attribution); Angelina Reader (Braille) = **no explicit license** (contact author). Apple frameworks and MIT components (WhisperKit, SpeakerKit, ISANet, BankNote-Net code) are the clean core.
