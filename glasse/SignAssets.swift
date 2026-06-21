//
//  SignAssets.swift
//  glasse
//
//  Maps fingerspelling steps to the visual the glasses lens should show. The Meta
//  Wearables Display API renders Image and VideoPlayer — but ONLY from HTTPS URLs
//  (no bundled assets, no file://; a blank/non-HTTPS URL throws
//  DisplayError.invalidVideoURL). So the actual handshape images and whole-word
//  sign clips must be HOSTED over HTTPS — GitHub Pages or an AWS S3 / GCP Cloud
//  Storage / Azure Blob bucket (Meta's own DisplayAccess sample serves its assets
//  from facebook.com and a GitHub raw URL).
//
//  This file is framework-neutral (Foundation only) so the rest of the app can
//  build a LensVisual without importing MWDATDisplay; GlassesDisplay.swift (gated
//  behind canImport(MWDATDisplay)) translates a LensVisual into the real
//  FlexBox / Image / VideoPlayer / Text and sends it to the lens.
//

import Foundation

/// A piece of content to show on the in-lens display, described independently of
/// the display SDK so non-display code can construct it.
enum LensVisual: Equatable {
    case text(title: String, body: String)
    case image(title: String, uri: String, caption: String)   // hosted handshape still
    case video(title: String, uri: String, caption: String)   // hosted sign clip (mp4)
}

enum SignAssets {

    // MARK: Configure these once you host the assets (HTTPS only)

    /// Base HTTPS URL holding one fingerspelling handshape image per character,
    /// named `a.png` … `z.png` and `0.png` … `9.png`. Served from the public repo
    /// github.com/MrFibonacc1/calHacksAI via raw.githubusercontent (the lens API
    /// rejects non-HTTPS / local URLs). Until the PNGs are uploaded there, the
    /// phone falls back to the letter glyph + a written handshape cue.
    static var handshapeBaseURL = "https://raw.githubusercontent.com/MrFibonacc1/calHacksAI/main/asl-assets/handshapes"

    /// Whole-word ASL sign clips: UPPERCASE word → hosted short `.mp4` URL. Words
    /// listed here play as a sign VIDEO on the lens; everything else is fingerspelled.
    /// A clip here takes priority over the text description below. Add entries as you
    /// upload clips to asl-assets/signs/ in the repo, e.g.:
    ///   "HELP": "https://raw.githubusercontent.com/MrFibonacc1/calHacksAI/main/asl-assets/signs/help.mp4"
    static var signClips: [String: String] = [:]

    /// Whole-word ASL sign STILLS: UPPERCASE word → hosted HTTPS image URL. Rendered
    /// as an `.image` on the lens when there is no `signClips` video for the word.
    /// Sourced from Wikimedia Commons (all CC BY-SA — attribution in
    /// ASL_IMAGE_CREDITS.md). Caveat: a single still can't show a sign's movement, so
    /// each pairs with its `signDescriptions` how-to as the caption. (URLs contain a
    /// percent-encoded "@" as %40 — keep them exactly as-is; don't double-encode.)
    static var signImages: [String: String] = [
        "HELLO":      "https://upload.wikimedia.org/wikipedia/commons/7/7c/Helloasl.png",
        "THANK":      "https://upload.wikimedia.org/wikipedia/commons/4/42/ASL_OpenB%40Chin-PalmBack.jpg",
        "THANKS":     "https://upload.wikimedia.org/wikipedia/commons/4/42/ASL_OpenB%40Chin-PalmBack.jpg",
        "YES":        "https://upload.wikimedia.org/wikipedia/commons/4/49/ASL_S%40Side-PalmForward.jpg",
        "NO":         "https://upload.wikimedia.org/wikipedia/commons/1/1f/ASL_Bent3%40Side-PalmForward.jpg",
        "PLEASE":     "https://upload.wikimedia.org/wikipedia/commons/8/87/ASL_OpenB%40Chest-PalmBack_RoundSplane.png",
        "NAME":       "https://upload.wikimedia.org/wikipedia/commons/4/45/ASL_H%40RadialFinger-H%40CenterChesthigh.jpg",
        "ILY":        "https://upload.wikimedia.org/wikipedia/commons/e/ec/ASL_ILY%40Side-PalmForward.jpg",
        "I LOVE YOU": "https://upload.wikimedia.org/wikipedia/commons/e/ec/ASL_ILY%40Side-PalmForward.jpg",
    ]

    /// A small phrasebook of common ASL signs as hand-authored "how to make it"
    /// descriptions — enough to start a basic conversation without any hosted video.
    /// These render as text on the lens / phone; a real clip in `signClips` for the
    /// same word overrides the description. Best-effort learning aid (see the app's
    /// experimental disclaimer) — ideally validated with a Deaf signer.
    static let signDescriptions: [String: String] = [
        // greetings & courtesy
        "HELLO": "Open flat hand at the side of your forehead, then move it outward like a salute.",
        "HI": "Raise your open hand and wave.",
        "BYE": "Wave, or open and close your fingers toward the person.",
        "GOODBYE": "Wave, or open and close your fingers toward the person.",
        "THANKS": "Fingers of a flat hand touch your lips, then move forward toward the person.",
        "THANK": "Fingers of a flat hand touch your lips, then move forward toward the person.",
        "PLEASE": "Rub your flat hand in a circle on your chest.",
        "SORRY": "Make a fist and rub it in a circle over your chest.",
        "WELCOME": "Open hand out to the side, palm up, then bring it in toward your body.",
        "NICE": "Slide the flat palm of one hand forward across your other open palm.",
        // responses
        "YES": "Make a fist and bob it up and down, like a nodding head.",
        "NO": "Snap your index and middle fingers down onto your thumb.",
        "GOOD": "Flat hand touches your chin, then moves down into your other open palm.",
        "BAD": "Flat hand touches your chin, then flips down so the palm faces down.",
        "FINE": "Spread your hand and tap your thumb on your chest, then move it forward a little.",
        // pronouns
        "I": "Point your index finger at your own chest.",
        "ME": "Point your index finger at your own chest.",
        "YOU": "Point your index finger toward the person.",
        "WE": "Point your index finger at one side of your chest, then arc it to the other side.",
        "MY": "Place your flat palm on your chest.",
        "MINE": "Place your flat palm on your chest.",
        "YOUR": "Open flat hand, palm out, push it slightly toward the person.",
        "NAME": "Make two U shapes (index and middle fingers) and tap them together twice.",
        // question words
        "WHAT": "Hold both open hands out, palms up, and shake them slightly.",
        "WHO": "Rest your thumb on your chin with your index finger pointing up, then bend the index finger a couple of times.",
        "WHERE": "Hold up your index finger and shake it side to side.",
        "WHEN": "Point one index finger up; circle the other index around it and land on its tip.",
        "WHY": "Touch your forehead, then bring your hand forward into a Y shape, palm toward you.",
        "HOW": "Put the backs of your curved fingers together, then roll your hands up to face palms up.",
        // common verbs & needs
        "HELP": "Rest a thumbs-up fist on your other flat palm, and lift both hands up together.",
        "NEED": "Bend your index finger into a hook and move it down firmly.",
        "WANT": "Hold both hands out, palms up, then pull them in toward you, curling your fingers into claws.",
        "EAT": "Bring your fingertips and thumb together and tap them to your lips.",
        "FOOD": "Bring your fingertips and thumb together and tap them to your lips.",
        "DRINK": "Make a C shape and tip it toward your mouth like a cup.",
        "WATER": "Make a W shape and tap your index finger on your lips.",
        "BATHROOM": "Make a T shape (thumb between index and middle) and shake it side to side.",
        "MORE": "Bunch the fingertips of each hand and tap the two bunched hands together.",
        "FINISH": "Hold both open hands up, palms toward you, then flip them out and down.",
        "DONE": "Hold both open hands up, palms toward you, then flip them out and down.",
        "WORK": "Make two fists and tap the wrist of one on top of the other.",
        "HOME": "Bunch your fingertips, touch your cheek near your mouth, then touch again a little toward your ear.",
        // feelings & social
        "LOVE": "Cross both fists over your chest.",
        "ILY": "Extend your thumb, index finger, and pinky (middle and ring fingers down), palm facing out — the “I love you” handshape.",
        "I LOVE YOU": "Extend your thumb, index finger, and pinky (middle and ring fingers down), palm facing out — the “I love you” handshape.",
        "HAPPY": "Brush your flat hand upward on your chest a couple of times.",
        "FRIEND": "Hook your index fingers together, then switch and hook them the other way.",
        "UNDERSTAND": "Hold a fist near your forehead, then flick your index finger up.",
        "KNOW": "Tap your fingertips on your forehead.",
        "LEARN": "Take info from your open palm and bring your bunched fingers up to your forehead.",
        "DEAF": "Point near your ear, then touch near your mouth.",
        "HEARING": "Roll your index finger in a small circle in front of your lips.",
    ]

    // MARK: Derived

    /// Words that have a whole-word sign — a hosted clip OR a phrasebook description —
    /// fed to FingerspellGuide.steps so they're signed rather than fingerspelled.
    static var signWords: Set<String> {
        Set(signClips.keys.map { $0.uppercased() })
            .union(signImages.keys.map { $0.uppercased() })
            .union(signDescriptions.keys)
    }

    /// The fixed vocabulary the experimental teach-mode sign RECOGNIZER supports
    /// (signer → captions). Start small (10); each must be taught once before it can
    /// be recognized. All have a how-to in `signDescriptions` to coach the recording.
    static let recognitionVocab: [String] = [
        "HELLO", "THANKS", "YES", "NO", "PLEASE",
        "HELP", "BATHROOM", "WHERE", "NAME", "WATER",
    ]

    /// How-to text for a whole-word sign: the phrasebook description, or a generic line.
    static func signText(for word: String) -> String {
        signDescriptions[word.uppercased()] ?? "Make the sign for \(word.uppercased())."
    }

    /// Best display text for any step: a sign's how-to for whole-word signs, else the
    /// step's own cue (handshape description / word-break / unsupported note).
    static func cue(for step: FingerspellStep) -> String {
        if case .sign(let word) = step.kind { return signText(for: word) }
        return step.cue
    }

    private static var handshapesConfigured: Bool {
        handshapeBaseURL.hasPrefix("https://") && !handshapeBaseURL.contains("CHANGE-ME")
    }

    /// Hosted handshape image URL for a letter/digit, or nil if not configured.
    static func handshapeURL(for ch: Character) -> String? {
        guard handshapesConfigured else { return nil }
        guard let c = String(ch).lowercased().first, c.isLetter || c.isNumber else { return nil }
        let base = handshapeBaseURL.hasSuffix("/") ? String(handshapeBaseURL.dropLast()) : handshapeBaseURL
        return "\(base)/\(c).png"
    }

    static func signClipURL(for word: String) -> String? { signClips[word.uppercased()] }

    static func signImageURL(for word: String) -> String? { signImages[word.uppercased()] }

    /// Best lens visual for a whole word: hosted sign video > hosted still image >
    /// the how-to text. Used by the .sign step case and direct callers (e.g. the Test
    /// screen). The still's caption is the word's how-to so the motion isn't lost.
    static func wordVisual(for word: String) -> LensVisual {
        let w = word.uppercased()
        if let uri = signClipURL(for: w) { return .video(title: "Sign “\(w)”", uri: uri, caption: w) }
        if let uri = signImageURL(for: w) { return .image(title: "Sign “\(w)”", uri: uri, caption: signText(for: w)) }
        return .text(title: "Sign “\(w)”", body: signText(for: w))
    }

    /// The lens visual for one step: a hosted sign video for whole-word signs, a
    /// hosted handshape image for letters/digits when configured, else a text cue.
    static func lensVisual(for step: FingerspellStep) -> LensVisual {
        switch step.kind {
        case .sign(let word):
            return wordVisual(for: word)
        case .letter(let c), .digit(let c):
            if let uri = handshapeURL(for: c) {
                return .image(title: "Fingerspell \(step.glyph)", uri: uri, caption: step.cue)
            }
            return .text(title: "Fingerspell \(step.glyph)", body: "\(step.glyph) — \(step.cue)")
        case .space:
            return .text(title: "Word break", body: "Pause briefly between words.")
        case .unsupported:
            return .text(title: "Skip", body: step.cue)
        }
    }

    /// The image URL to show on the PHONE for a step (handshape stills only — the
    /// phone uses AsyncImage, which doesn't play sign-clip videos).
    static func phoneImageURL(for step: FingerspellStep) -> String? {
        if case .image(_, let uri, _) = lensVisual(for: step) { return uri }
        return nil
    }
}
