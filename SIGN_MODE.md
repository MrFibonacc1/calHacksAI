# Sign-language → captions on the Ray-Ban Display — research & plan

## ✅ Built (2026-06-20): experimental Fingerspelling reader
Implemented exactly the recommended on-device path below.
- **Model:** Apple Vision `VNDetectHumanHandPoseRequest` (on-device CNN, 21 joints, no frames leave the phone) → a geometric letter classifier.
- **`SignClassifier.swift`** — pure, dependency-free (Foundation + CoreGraphics only) so it's unit-testable with `swiftc`. Classifies the distinct static subset (A, B, D, F, I, L, U, V, W, Y, O, K…) from finger extension / spread / pinch geometry; ambiguous or motion shapes return low confidence. **Tested: 11/11 synthetic-handshape cases pass.**
- **`SignAssembler.swift`** — pure temporal layer (debounce over ~6 frames, word assembly, open/no-hand = space). Also dependency-free + **unit-tested (11/11)**.
- **`SignReader.swift`** — `@Observable @MainActor`; runs Vision off-main (`Task.detached`) with a drop-frame guard + a generation token that discards in-flight detections after stop/reset; delegates temporal logic to `SignAssembler`.
- **`SignView.swift`** — full-screen mode: live aim view, big current-letter glyph with a low/med/high **confidence chip** (low → `(?)`), assembled captions, mirrors to the in-lens display, explicit "experimental, not an interpreter" banner. Ordered start/stop (teardown awaits any in-flight stream start) and clears the lens on exit.
- **Entry:** "Read fingerspelling" row on the main screen → the `sign_reading` capability node now has a real backend.
- **Tested:** classifier 11/11 + temporal assembler 11/11 (`swiftc`); builds green on simulator + device; launch smoke test passes. Adversarially reviewed (3 dimensions) → 9 findings (6 distinct) all fixed (start/stop stream race, stale lens text, in-flight result bleed, stale confidence chip).
- **Not yet verified:** real-hand accuracy needs on-device camera testing; expect ~60–75% letter accuracy in the wild (see below).

## Bottom line
- **Verbatim, continuous ASL → captions is not solvable in a hackathon** (or as a product in mid-2026). Best continuous-sign systems are ~15–20% word-error only on clean studio data and collapse in the wild.
- **Frontier VLMs — including Claude — cannot read signs from frames.** Benchmark (*Visual Iconicity Challenge*, 2026): on isolated single signs, open-set, GPT-5 ≈ 15.6%, Gemini-2.5-Pro ≈ 17.7% (a human deaf expert ≈ 59%). A constrained multiple-choice list lifts VLMs only to ~42–44%. So "send glasses frames to Claude and ask what they signed" would be wrong most of the time and is slow — **not** a viable recognizer. (This refuted our first idea — good we checked.)
- **The only real-time, on-device path is hand-pose landmarks → a small classifier, scoped to FINGERSPELLING** (spelled letters/names/numbers), optionally plus a tiny fixed set of whole signs.
- **There is no turnkey sign-recognition API on AWS, GCP, or Azure** (they sell only generic CV/VLM blocks; AWS GenASL goes the *opposite* way, English→ASL avatar). Don't go hunting for one.

## Recommended build — an on-device "Fingerspelling reader" mode
Apple **Vision `VNDetectHumanHandPoseRequest`** (21 joints/hand, on-device, free, Neural-Engine) → small Core ML classifier. Reuses patterns already in the repo.

1. **New mode:** add a `sign` case to `AgentKind` (alongside `.vision`, `.captions`), user-selectable.
2. **Frames:** tap `currentVideoFrame`, throttle ~12–15 fps off the main actor (mirror `ObjectDetector.process`'s `Task.detached` + drop-frame guard). Request lower res/fps from the glasses — finer finger detail beats field of view here.
3. **Landmarks:** run hand-pose off-main; gate on hand-present confidence to segment signing vs. rest (no pixels leave the device).
4. **Classify (two options by time):**
   - **Buildable-in-hours fallback:** a per-letter kNN/MLP on normalized single-frame landmarks for the **24 static A–Z letters** (skip motion letters J/Z), with a quick in-app "teach the letters" calibration.
   - **Higher-accuracy stretch:** port the Kaggle ASL-Fingerspelling 1st-place recipe (Squeezeformer + transformer decoder over landmark *sequences*) to Core ML via `coremltools` from the source PyTorch/TF graph (no clean TFLite→Core ML path). Riskier; may eat the whole budget.
5. **Assemble:** accumulate letters into words with a small dictionary auto-correct; optionally pass the assembled string to Claude **text-only** as a "spell-check this fingerspelled string into a likely name/word" smoother — *never* as the recognizer.
6. **Output:** push word/pause boundaries to the lens via `GlassesDisplayManager.show(title:body:)`; optionally speak via the existing `AudioCoordinator`/TTS path.
7. **Confidence UX (mandatory):** show a low/med/high confidence chip and render low-confidence letters as `(?)` instead of guessing silently.

Sub-second updates, no network. ~1–1.5 days for the static-letter version; start there.

## Realistic expectations (and how to frame it)
- **Will:** read deliberately, slowly fingerspelled letters → names/numbers at close-ish range, roughly front-facing; optionally a tiny fixed whole-sign set (PopSign hit ~82–84% on 250 signs, ~99% only when the active vocab is a few candidates).
- **Will NOT:** translate fluent signed *sentences*; capture facial/grammatical meaning (hand-only models discard it); reliably do motion letters from static frames; or hit benchmark numbers in your setting. Published figures are clean-studio **ceilings**; first-person, oblique, small-hand, 720p, BT-compressed → expect **~60–75% letter accuracy in the wild** (our estimate, not a guarantee).
- **Frame it:** call it a **"Fingerspelling reader"** — *experimental, best-guess, reads spelled names + a few signs.* Explicitly **not a real-time ASL translator and not a substitute for a qualified human interpreter.** Overclaiming "translate a Deaf person's sentences" is the exact failure the Deaf community has repeatedly criticized.

## Best honest story: make it two-way
The hard half is signer→wearer. The wearer→signer half is **already solid**: the existing `SpeechCaptioner` shows the hearing wearer's speech as live captions to the deaf signer. Pairing reliable speech captions (wearer side) with a humble fingerspelling reader (signer side) is a far more honest, complete "let a hearing person and a Deaf signer converse" demo than overclaiming sign translation.

## Ethics & privacy
- **Consent first** — video of someone signing is highly identifying, and "Deaf" is sensitive data. Get explicit consent and show a recording indicator.
- **On-device by default** — landmarks never leave the phone; gate any cloud (the optional Claude smoother) behind explicit consent (and AWS/GCP/Azure only).
- **Never imply certainty** — confidently captioning the wrong words for a Deaf person is actively harmful. Always show uncertainty; state it's experimental; ideally validate with a Deaf signer and disclose it's built by a hearing developer. Captioning ≠ interpreting.
