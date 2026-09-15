# AirKey

A macOS menu-bar keyboard controlled with your hands. Aim with the midpoint between your index finger and thumb, pinch to press a key, or hold a pinch and glide through a word. AirKey types into the focused text field in another app.

- English and Spanish suggestions, spelling alternatives, and swipe typing.
- Large floating keys, an optional live hand hologram, and mouse input.
- A magnetic **Move** handle, Space, and Delete for easier targeting.
- Local personal vocabulary and learning from confirmed suggestions and corrections.
- Automatic transparency and camera pausing when idle.

AirKey is an experimental keyboard. Accuracy depends on lighting, camera position, and keeping both fingertips visible. It is still being improved for fast, reliable typing.

## Requirements

- macOS 13 or later. Building requires a macOS version supported by your installed Xcode.
- Xcode with **Swift 6.2 or later**. Open Xcode once and finish its component installation.
- A camera for hand input. Mouse clicks work without camera access.
- Camera permission for tracking and Accessibility permission for typing into other apps.

There are no third-party Swift package dependencies, accounts, or API keys to configure. English and Spanish dictionaries are included; normal use works offline.

## Build and launch

Open Terminal and clone the repository:

```bash
git clone git@github.com:esxph/airkey.git
cd airkey
./Scripts/run-app.sh
```

For a public clone without GitHub SSH setup, use `git clone https://github.com/esxph/airkey.git` instead. If you already downloaded the source, open Terminal in that folder and run `./Scripts/run-app.sh`.

The script builds in release mode, packages the executable and dictionaries into `.build/AirKey.app`, signs the app locally, and launches it. Look for the **keyboard icon in the menu bar**; AirKey has no Dock icon.

To launch the existing build later, double-click `.build/AirKey.app` in Finder, or run this from the repository folder:

```bash
open .build/AirKey.app
```

Before rebuilding, choose **Quit AirKey** from its menu. Use the same app location and signing identity across rebuilds to help keep macOS permissions consistent.

If Terminal is using the standalone Command Line Tools or an older Xcode, select your installed Xcode for this command:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/run-app.sh
```

Adjust that path if Xcode is installed elsewhere. Check the selected compiler with `xcrun swift --version`.

### First-run permissions

1. Allow **Camera** access when prompted. If previously denied, enable AirKey in System Settings → Privacy & Security → Camera, then choose **Start / retry camera** in AirKey's menu.
2. In AirKey's menu, choose **Enable typing into apps…**. Enable this copy of AirKey in System Settings → Privacy & Security → **Accessibility** (called **Device Control and Data Access** on some macOS versions).
3. Click an editable field in another app, such as a new TextEdit document. Use AirKey's keys or suggestions. The floating keyboard keeps the destination app focused.

AirKey reads the system-wide keyboard focus before sending input and checks that the focused field belongs to that app. Changing apps or fields clears the previous word context. If focus is unavailable or changes during the check, input pauses rather than using an old destination. The menu shows the current destination or the reason typing is paused.

**If the permission switch is already on but typing fails:** choose **Reveal this app in Finder** to identify the running copy. Remove its stale AirKey entry from the permission list, add this exact `.build/AirKey.app` using the `+` button, and enable it. macOS may require your authentication. Relaunch AirKey if needed, then click the destination field again.

For everyday use, launch the packaged `.app`. `swift run` and the default Swift package Run action in Xcode launch a bare executable without the app bundle's permission configuration. Stop any Xcode debug run before launching the packaged copy.

### Local signing

The script uses an available **Apple Development** or **Developer ID Application** certificate from your Keychain. You can select one explicitly:

```bash
AIRKEY_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./Scripts/run-app.sh
```

Without a suitable certificate it falls back to ad-hoc signing, which is enough to build locally but can require granting permissions again after a rebuild. Certificates and private keys are not included in this repository. These are local development builds, not notarized distribution releases.

## Using the keyboard

| Action | How |
| --- | --- |
| Aim | Open your index finger and thumb. The circle stays centered between their tracked tips. Moving your whole hand moves the cursor. |
| Press a key | Pinch thumb and index finger together, then open them before the next press. Either hand can type. |
| Accept a suggestion | Pinch or click a word above the keys. It inserts a trailing space. |
| Swipe a word | Enable **Swipe typing** in the menu. Pinch at the first letter, keep holding while gliding through the word, and release at the last letter. |
| Correct a swipe | Choose another candidate immediately after the word, or use **Undo** in the menu. Uncertain paths ask you to choose a candidate. |
| Delete | Pinch or click Delete. Holding a pinch repeats deletion after a short delay. |
| Enter symbols | Use **123**; use **ABC** to return to letters. |
| Move the keyboard | Drag the top-right **Move** handle with the mouse, or aim near it and hold a pinch while moving your hand. Release to place it. |
| Change settings | Click the menu-bar keyboard icon or right-click the keyboard. |

The Move handle, Space, and Delete attract nearby hits without taking direct hits on letters or suggestions. Window placement is saved. Holding the Move handle suspends typing until you release it.

The keyboard maps into the central 76% of the camera image, leaving at least a 12% tracking margin at each edge. You can reach the outer keys while both fingertips remain inside the frame. The hand hologram and fingertip guides share this mapping, and the circle stays at their midpoint. Camera movement covers more keyboard distance with a constant scale; there is no extra edge acceleration or cursor snapping. During a held window drag, the highlight stays on Move rather than keys underneath the cursor.

Choose **Language → Español / English** and **Pinch effort → Light / Standard / Firm** in the menu. Use Light for missed presses or Firm for accidental presses, then reopen your hand. To switch from a resting hand to that hand typing, move it to aim, open your fingers, and pinch again.

Spelling suggestions never silently replace ordinary tapped words. A **Fix:** suggestion explicitly replaces the previous word. Swipe typing can insert its best match automatically; alternatives and Undo let you correct it.

### Moving out of the way

The keyboard is translucent while active. By default:

- After **8 seconds idle**, it becomes fully transparent and lets mouse clicks through. A small corner tab remains.
- While the camera is still running, deliberate **open-hand movement** can reveal the keyboard. Reopen and make a fresh pinch to type after it returns.
- After **45 seconds idle**, it tucks into the corner and pauses the camera. Click the tab or choose **Show keyboard** to resume.
- **Tuck in full screen** hides it when a foreground full-screen window covers its display and you are idle outside an editable field. This checks window coverage; it does not detect every video player or windowed video.

Change these behaviors under **Automatic hiding**. **Tuck into corner / pause camera** leaves the restore tab; **Hide keyboard / pause camera** hides the panel until you show it from the menu.

### Practice and personal learning

Use **Typing test…** for a separate practice window with words per minute, remaining character errors, corrections, and tracking timing. Practice does not send text to another app or add learning samples. Mouse or physical-keyboard assistance is identified in the result.

Under **Learning and protection**, you can pause personal learning, teach the current word, reset the profile, or change resting-hand protection. Confirming a suggestion teaches word preferences and, for swipe alternatives, a compact path example. **Accidental pinch** can undo an eligible resting-hand press and strengthen protection for that hand. These are bounded statistical updates; AirKey does not retrain a neural hand detector or automatically change pinch effort.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| Keys react but no text appears | Check the permission steps above, click the destination field again, and read the destination/permission status in AirKey's menu. Try TextEdit to distinguish an app compatibility issue. |
| A particular field does not work | It must expose an editable field through macOS Accessibility. Password/secure fields are excluded. Some fields allow direct typing but do not expose the selection information needed for suggestion replacement or Undo. |
| Cursor flickers or presses are missed near an edge | Keep both fingertips inside the camera frame, improve lighting, and avoid occlusion. Brief tracking loss pauses input; longer loss requires reopening your hand. |
| The other hand types accidentally | Keep **Resting-hand protection** enabled. Use **Accidental pinch** immediately after an eligible unwanted tap. |
| The keyboard disappeared | Click the corner tab or choose **Show keyboard** in the menu. Review **Automatic hiding** if it hides too soon. |
| CPU use is high | Use a release build, disable **Appearance → Hand hologram**, and tuck or hide the keyboard when finished. This stops camera processing. |
| Build fails after changing Xcode | Finish Xcode setup, check `xcrun swift --version`, and use `DEVELOPER_DIR` as shown above. |

The hologram is an approximate cutout of live hand pixels. Similar-colored backgrounds and occlusion can affect its outline; it is not a privacy filter. For tracking issues, **Copy tracking report** provides aggregate counts and processing times without camera images or typed text.

## Privacy

Camera frames, hand tracking, suggestions, and learning stay on your Mac. The app does not save camera recordings or upload input. It uses Accessibility to inspect the focused field and selection positions and to send key events; it does not read the destination's full document or monitor physical keystrokes.

Personal vocabulary, word counts, and compact confirmed swipe examples are stored in:

```text
~/Library/Application Support/AirKey/personal-learning.json
```

Use **Reset personal learning** to clear that profile. Presentation preferences and window placement are stored separately in macOS user defaults. Neither belongs in the source repository.

## Development

Open `Package.swift` in Xcode to edit the project. From Terminal:

```bash
# Run the regression suite
swift test -c release

# Build and package without launching
./Scripts/run-app.sh --no-open

# Build a debug app
CONFIGURATION=debug ./Scripts/run-app.sh --no-open
```

Tests cover gesture transitions, tracking continuity, fingertip projection, control targeting, movement, hiding, English/Spanish suggestions, swipe decoding, personal learning, and ordered text edits. Synthetic tests and decoding timings do not establish real-user typing speed or end-to-end accuracy. Check actual camera input and typing into another app before shipping gesture or output changes.

| Path | Purpose |
| --- | --- |
| `Sources/airKey/` | Native SwiftUI/AppKit app, camera and Vision tracking, gesture engine, typing controller, and language engine. |
| `Sources/airKey/Resources/` | Bundled dictionaries and their attribution. |
| `Tests/airKeyTests/` | Regression tests and synthetic swipe benchmarks. |
| `Scripts/run-app.sh` | Local build, app packaging, signing, and launch. |
| `Scripts/update-lexicons.py` | Reproducible dictionary generation from a pinned upstream revision. |

Build products, Xcode user state, logs, and signing material are excluded by `.gitignore`.

## License and dictionary attribution

AirKey's application code is available under the [MIT License](LICENSE), copyright © 2026 Edward Hunter. The bundled dictionary data has separate terms below; the MIT license does not replace them.

The English and Spanish word lists are adapted from Hermit Dave's [FrequencyWords](https://github.com/hermitdave/FrequencyWords), based on OpenSubtitles 2018, at revision `525f9b560de45753a5ea01069454e72e9aa541c6`. The dictionary data remains under **CC BY-SA 4.0**, separately from the application code. See [ATTRIBUTION.txt](Sources/airKey/Resources/ATTRIBUTION.txt) for source and license links and the modifications made.

To regenerate the included lists, run `python3 Scripts/update-lexicons.py`. Only this optional development step downloads the pinned source data; normal builds and use do not download dictionaries.
