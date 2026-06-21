# ASL sign-image credits

The whole-word ASL sign images shown on the lens (configured in
`glasse/SignAssets.swift` → `signImages`) come from **Wikimedia Commons** and are
**copyleft (CC BY-SA)** — not public domain. Displaying them requires:

1. **Attribution** — credit the author + a link to the license (below).
2. **ShareAlike** — if you *modify* an image (crop/recolor/composite), the
   derivative must be released under the same or a compatible license. We display
   them **unmodified**, so ShareAlike is not triggered by display alone.

> For a production app, surface these credits in-app (e.g. an About/Credits screen)
> and consider **self-hosting** the files (Wikimedia permits hotlinking but
> recommends mirroring; it doesn't guarantee stable paths). GitHub Pages on the
> `calHacksAI` repo is the approved host for that.

| Word | License | Author / source | Commons file |
|---|---|---|---|
| HELLO | CC BY-SA 4.0 | "hello in ASL" by wpclipart.com | [File:Helloasl.png](https://commons.wikimedia.org/wiki/File:Helloasl.png) |
| THANK / THANKS | CC BY-SA 3.0 (+GFDL) | Rodasmith (subj. Kaitlin Williams, Bellevue College) | [File:ASL OpenB@Chin-PalmBack.jpg](https://commons.wikimedia.org/wiki/File:ASL_OpenB@Chin-PalmBack.jpg) |
| YES | CC BY-SA 3.0 (+GFDL) | Rodasmith (subj. Megan Snyder) | [File:ASL S@Side-PalmForward.jpg](https://commons.wikimedia.org/wiki/File:ASL_S@Side-PalmForward.jpg) |
| NO | CC BY-SA 3.0 (+GFDL) | Rodasmith (subj. Lauren Richards) | [File:ASL Bent3@Side-PalmForward.jpg](https://commons.wikimedia.org/wiki/File:ASL_Bent3@Side-PalmForward.jpg) |
| PLEASE | CC BY-SA 4.0 (+GFDL) | Rodasmith (edit of a photo of native signer M. Cooper) | [File:ASL OpenB@Chest-PalmBack RoundSplane.png](https://commons.wikimedia.org/wiki/File:ASL_OpenB@Chest-PalmBack_RoundSplane.png) |
| NAME | CC BY-SA 3.0 (+GFDL) | Rodasmith (subj. Trang Pham) | [File:ASL H@RadialFinger-H@CenterChesthigh.jpg](https://commons.wikimedia.org/wiki/File:ASL_H@RadialFinger-H@CenterChesthigh.jpg) |
| ILY / I LOVE YOU | CC BY-SA 4.0 (+GFDL) | Rodasmith | [File:ASL ILY@Side-PalmForward.jpg](https://commons.wikimedia.org/wiki/File:ASL_ILY@Side-PalmForward.jpg) |

## Accuracy caveats (be honest in the demo)
- **Stills of motions.** Most signs move; these are single frames. THANK YOU / YES /
  NO show only the *first* posture; NAME shows the *final* posture; HELLO and PLEASE
  encode the movement with an arrow/graphic. Each image is paired with its how-to
  text as a caption to compensate.
- **THANK YOU's start posture resembles GOOD** — don't rely on the still alone.
- **"LOVE" is shown as the ILY ("I love you") handshape**, *not* the citation LOVE
  sign (crossed fists) — no openly-licensed still of crossed-fists LOVE was found, so
  it's mapped under `ILY` / `I LOVE YOU`. The word `LOVE` itself still shows the
  crossed-fists how-to **text**.
- Only HELLO and ILY were visually confirmed; the others are confirmed reachable +
  labeled correctly on Commons but not visually inspected.

## No image yet (fall back to how-to text)
SORRY, HELP, WATER — no openly-licensed still found (correct depictions existed only
on copyrighted dictionary sites). They render as their `signDescriptions` text.
