# Braille reader — on-device model setup

The app has an on-device Braille reader (`glasse/BrailleReader.swift`) wired as the
**primary** path for `read_text` ("glasses, what does this say"), with **Claude
vision as the fallback**. It uses **DotNeuralNet** (YOLOv8, **MIT** license) — a
pretrained model where each detection box *is* one Braille cell (class label = the
6-bit dot pattern). The Swift side is done and degrades gracefully: until the model
is in the bundle, `BrailleReader` reports unavailable and `read_text` just uses
Claude — so the build and the existing behavior are unaffected.

To turn the on-device reader on, do this once (needs a Mac + Python — I can't run it):

## 1. Export the model to Core ML
```bash
pip install ultralytics coremltools
# DotNeuralNet weights are MIT-licensed and committed in the repo (git LFS):
#   https://github.com/snoop2head/DotNeuralNet  (weights/yolov8_braille.pt)
git clone https://github.com/snoop2head/DotNeuralNet
cd DotNeuralNet && git lfs pull
python -c "from ultralytics import YOLO; YOLO('weights/yolov8_braille.pt').export(format='coreml', nms=True, imgsz=[640,640])"
# → produces yolov8_braille.mlpackage
```

## 2. Add it to Xcode
- Rename the export to **`BrailleYOLO.mlpackage`** (the code looks up `BrailleYOLO`).
- Drag it into the `glasse` target in Xcode (check **Target Membership: glasse**).
  Xcode compiles it to `BrailleYOLO.mlmodelc` in the bundle, exactly like
  `ISANet.mlmodelc`.
- It's ~12–25 MB (FP16). Consider gitignoring it like `ISANet.mlmodel`.

## 3. Verify the class labels (important)
The code reads each detection's class label as a **6-bit string** like `"100100"`
(dots 1–6) and computes the Unicode Braille char from it. After export, check the
model's class names (`model.names`):
- If they're the 6-bit strings → works as-is.
- If Ultralytics renamed them to indices → map index→pattern in
  `BrailleReader.decode` (one small change).

## 4. Test on a real device
Core ML inference does **not** run on the iOS Simulator — test on glasses/device.
Point at a clean, flat, well-lit **Grade-1 (uncontracted)** Braille label and say
"glasses, what does this say."

## Honest scope
- **Wins over Claude:** clean Grade-1 Braille — offline, instant, deterministic, free.
- **Falls back to Claude:** Grade-2 (contracted) Braille (books/menus/transit — the
  common case), and faint/curved/skewed/low-contrast Braille. The reader hands its
  low-confidence cells to Claude as an anchor in those cases.
- This consumes only MIT weights + code (fine for a hackathon). Flag the training-data
  provenance if this ever ships commercially.

## Stretch: true Grade-2 offline
Add **liblouis** (xcframework + `en-us-g2.ctb`) to back-translate contractions on-device
(heavier: cross-compile + LGPL review). Until then, Claude handles contractions.
