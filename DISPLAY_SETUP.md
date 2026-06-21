# Ray-Ban Display lens — how it was enabled (VERIFIED WORKING)

✅ The in-lens Display works on a **FREE Apple account** — no paid Apple Developer Program, no Universal Link, no Associated Domains. This was confirmed end-to-end on real hardware.

## The key facts (that took a while to learn)
- **Meta DAT uses a custom URL scheme** (`glasse://`) for the registration callback — **not** an https Universal Link. So **Associated Domains (paid-only on Apple) is irrelevant.** The camera and display share this same registration.
- The "should be a universal link" line in Meta's docs is advisory/production-only, not enforced. In Developer Mode, registration is always allowed.
- The GitHub Pages site / Universal Link we set up earlier was **unnecessary** (harmless, ignore it).

## The working configuration

### 1. Info.plist `MWDAT` dict (committed)
```xml
<key>MWDAT</key>
<dict>
    <key>AppLinkURLScheme</key>
    <string>glasse://</string>                 <!-- custom scheme, NOT a universal link -->
    <key>MetaAppID</key>
    <string>1049074614299437</string>
    <key>ClientToken</key>
    <string>AR|YOUR_META_CLIENT_TOKEN</string>
    <key>TeamID</key>
    <string>$(DEVELOPMENT_TEAM)</string>
    <key>DAMEnabled</key>
    <true/>                                     <!-- DAT App Model; required for Display -->
</dict>
```
No Associated Domains entitlement. No `applinks:`.

### 2. Wearables Developer Center (one-time)
- Register the app (bundle `com.huzaifa.glasse`, Team ID `7NYK44UHSQ`) → it auto-generates the `MetaAppID` + `ClientToken` above.
- Create a **version** → wait for **Ready**.
- Create a **release channel** → add your own Meta account as tester.

### 3. Glasses (the step that actually lit the lens)
- Keep **Developer Mode** on (Meta AI app → glasses → Settings).
- In the **Meta AI app**, when the glasses (e.g. "Meta RB Display 006X") show an **Install** button → **tap Install**. This stages the on-glasses display bundle (the DAT runtime). This is what fixes `addDisplay()` failing / "no display-capable device" / the camera "failed to start session".

### 4. Build & run
- ⌘R to the physical iPhone, connect glasses, and the lens renders.

## Gotchas learned the hard way
- **Enabling `DAMEnabled` BEFORE the on-glasses bundle is installed breaks the camera** ("failed to start session"). Install the bundle first (step 3), then enable `DAMEnabled`.
- Two accounts can share one email: the **Wearables Developer Center** uses a Managed/work Meta account; the **Meta AI app + glasses** use a personal Meta account. The release-channel tester must be the account that's actually on the phone.
- Free Apple account limits: 7-day provisioning-profile expiry, 3-device cap — operational only, not a display blocker.

## How content reaches the lens (in code)
- `GlassesDisplay.swift` → `display.send(FlexBox { Text(title); Text(body) })`.
- `ContentView.mirrorToLens(title, body)` routes descriptions, captions, object labels, and voice replies to the lens (gated behind `canImport(MWDATDisplay)`).
- Refinement if camera + display run together: call `addDisplay()` on the **existing camera DeviceSession** rather than a separate `AutoDeviceSelector(filter:{ $0.supportsDisplay() })` session (which can throw `noEligibleDevice`).
