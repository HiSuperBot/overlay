# Overlay

A project hub for camera and face-overlay experiences. The native iOS app lives in `apps/ios`.

The camera offers **Video** and **AI** capture modes, separately from **Original**, **Mesh**, and **Avatar** face effects. Both modes show a live preview before recording. Avatar replaces the tracked face with **Human A** or **Human B**, including animated eyes, lips, brows, lashes, teeth, and mouth interior. A feathered face mask keeps the camera's hair, neck, body, and background outside the replacement region.

Tap **Face** in the camera footer to open a bottom sheet with **Original**, **Mesh**, **Human A**, and **Human B** cards. The current choice has a checkmark. Selecting a card immediately applies it and closes the sheet; closing or dragging the sheet down without selecting keeps the current effect. The sheet starts at medium height and can expand. Camera capture and face calibration continue while it is open. Loading, fit status, **Re-fit**, and error feedback remain on the camera screen.

In **Video**, tap the **red circle** to record the current camera effect with microphone audio. It becomes a red stop square and shows **REC** with elapsed time. Tap again to finish and automatically save to Photos. Allow microphone and add-only Photos access when prompted. Mode selection, Face selection, and Re-fit are locked during preparation, recording, and saving. Avatar recording requires a loaded, fitted face. The saved video contains the composited preview with the same unmirrored direction and crop; interface controls are excluded.

In **AI**, the preview and record controls look the same, but the app saves **original camera video + microphone audio + TrueDepth data** inside the app. The original H.264 video retains sensor resolution and the full field of view, without avatar pixels, viewport cropping, or mirror reflection. Depth preserves native floating-point measurements and calibration, including timestamps and missing samples. AI requests microphone access and does not request Photos access or save to Photos. This mode prepares data for later AI processing; it does not run a model or upload footage.

Open **AI Captures** from the header to list saved bundles, play original footage, inspect depth information/a sample heatmap, export all files as ZIP, or confirm deletion. Interrupted/incomplete data is labeled and retained. Capturing requires at least 512 MiB free space and stops below a 256 MiB reserve. The initial mode is Video; the last choice is saved.

- iOS 18 or later, portrait orientation, one face, and a supported TrueDepth front camera.
- One ARKit capture session shared by Metal and RealityKit.
- A supported 30fps capture format in Avatar mode and during recording; faster diagnostic capture when idle where available.
- An initial continuous neutral second fits the face. **Re-fit** repeats calibration; avatar changes reuse the measurements.
- Asynchronous local model loading with the last selection winning. Human A is the initial default and the selected avatar ID is saved.
- Original-camera fallback and an error message when an avatar cannot load.
- H.264 MP4 with AAC audio, targeting 30fps. Video mode keeps the preview aspect within 1080 × 1920; AI mode keeps original sensor dimensions.
- All capture, tracking, loading, rendering, and encoding run on the iPhone. Video and microphone audio are saved only when recording is requested. Face tracking data is not exported or transmitted.
- Leaving the foreground or losing camera/microphone availability ends the clip. Tracking loss alone records the existing camera fallback and restores the effect when tracking returns.
- If Photos saving fails, the completed clip is kept in application storage with **Retry save** and **Share**. Pending clips survive relaunch and are removed only after Photos confirms saving.

Hands, glasses, and bangs can currently be covered if they enter the face mask. Full head replacement, still photos, pause/resume recording, and AI conversion are outside this version. Actual preview speed, temperature, expression fidelity, audio synchronization, depth delivery, and alignment require device validation.

## Repository layout

```text
assets/avatars/              # Editable Blender sources, conversion scripts, licenses
apps/ios/
├── Overlay.xcodeproj/
└── Overlay/
    ├── App/                 # Application entry point
    ├── Avatars/             # Catalog, expression mapping, calibration, frame driver
    ├── Features/Camera/     # SwiftUI screen and shared preview host
    ├── Features/AICaptures/ # Local capture library, playback, depth inspection, sharing
    ├── AICapture/           # Original-data writer, depth journal, recovery, ZIP export
    ├── Tracking/            # Permissions, ARSession, frame delivery, camera state
    ├── Rendering/           # Diagnostic renderer, avatar compositor, Metal shaders
    ├── Recording/           # Recording state, bounded GPU frame sink, movie writer, Photos saving
    └── Resources/Avatars/   # Two USDZ models, thumbnails, catalog
scripts/check_sources.sh     # Lightweight checks; never starts Xcode or a simulator
tests/                      # Standalone Swift unit tests
docs/                       # Rendering architecture and device checks
```

See [avatar provenance and reproduction](assets/avatars/README.md), [rendering architecture](docs/avatar-preview.md), [recording architecture](docs/recording.md), and [AI capture format](docs/ai-capture.md).

## Run

Open `apps/ios/Overlay.xcodeproj` in Xcode and select the **Overlay** scheme (bundle ID `com.mindware.Overlay`). Select your development team under **Signing & Capabilities**, choose your connected TrueDepth iPhone, build and run, and allow camera access. A Personal Team can be used for development testing.

If Xcode reports a missing Metal Toolchain, install Apple's compiler component:

```sh
xcodebuild -downloadComponent MetalToolchain
```

Xcode resolves the pinned **ZIPFoundation 0.9.20** package for ZIP export. Its MIT license is bundled in `Resources/Licenses/ZIPFoundation.txt`. The simulator displays the interface and a device requirement message. It cannot validate TrueDepth, facial expressions, or face replacement. Full builds, simulator sessions, and device runs are performed manually in this repository.

## Lightweight validation

```sh
./scripts/check_sources.sh
```

This checks Swift against the iOS 18 deployment target, including strict concurrency and intermediate-representation diagnostics with warnings treated as errors, compiles Metal shaders, checks the project and packaged assets, and runs standalone Swift tests for calibration, face fitting, expression mapping, and a filled 3D face mask through yaw/pitch. Outputs stay in a temporary directory. It does not build or run the app. To also check actual RealityKit USDZ import on macOS 15 or later, use `./scripts/check_sources.sh --realitykit`. This optional standalone asset check verifies 52 imported expressions, separate eye pivots, and PBR materials without creating a camera session or window. Use `--avatar-mask` to exercise the actual Metal mask shader with rotated nose/eye/mouth cases and mask clearing in an offscreen test.

Recording dimension/timeline tests, dependency/license settings, and permission-description checks run by default. Use `./scripts/check_sources.sh --recording` to generate and decode short composited H.264/AAC clips on macOS 15 or later. Add **`--ai`** to test original NV12 video, four depth formats, independent timing, missing samples, atomic pair drops, journal recovery, ZIP file equality, deletion, and storage limits. Checks use synthetic data and never open a camera, simulator, or app window. Optional flags can be combined. Source checking fetches the pinned ZIPFoundation source into a temporary cache on its first run.

## Device checklist

1. Tap **Face**: the sheet starts at medium height, expands, and closes with its close button or a downward drag. Keep the sheet open and confirm the camera remains live. Dismiss without selecting and confirm the effect and completed fit are retained.
2. Select each of **Original**, **Mesh**, **Human A**, and **Human B**. Each selection closes the sheet and updates the footer name. Reopen it and verify only the current choice is checked. Switch directly from Mesh to each human face.
3. In Avatar mode, look straight ahead and relax your face for one second. Blink, speak, and move your gaze. Try **Re-fit**. Rapidly reopen the sheet and switch avatars; verify the last selection wins.
4. Re-fit while facing forward, then check frontal and approximately ±30°/±45° head turns plus looking up/down. In both Human A and Human B, check for a straight cut through the nose/mouth, exposed real eyes/mouth, gaps, or large boundary offsets. Hold each pose still to distinguish persistent shape mismatch from motion lag. Check that Original, Mesh, Human A, and Human B have the same unmirrored direction and crop. Hold up readable text and confirm it stays readable when switching effects.
5. Confirm hair, neck, body, and background remain camera pixels outside the feathered boundary.
6. Leave the frame and return. Background and resume the app with the selector open, then make another selection. Check for black output or an old face.
7. Use Avatar for five minutes and assess smoothness and temperature. A 30fps capture target is not a measured performance guarantee.
8. Deny camera permission and verify **Open Settings**. Verify the simulator's unsupported-device message.
9. Record each of Original, Mesh, Human A, and Human B. Check the stop square, elapsed time, disabled Face/Re-fit controls, and **Saved to Photos**. Play each clip in Photos: check audio, lip synchronization, crop, colors, and the same unmirrored direction as the preview, with no interface controls in the video.
10. Stop a short clip, start another, leave the frame, return, background/resume, and interrupt microphone capture. Completed clips should save, recording should not resume automatically, and the next recording should work. Deny microphone/Photos access and verify Settings guidance. If a Photos transaction fails, test Retry save, Share, and recovery after relaunch.
11. Record for five minutes and assess preview smoothness, saved-video smoothness, temperature, and memory stability.
12. Switch Video/AI, confirm the last choice survives relaunch, and verify capture/face controls lock while busy. A previously saved Preview selection should open as Video. In AI, test each face effect: the preview uses the effect, the library's video shows the actual original face, and Photos has no new recording. A fresh AI-only run should request microphone access but no Photos access.
13. Inspect the saved bundle's depth counts, calibration availability, gaps, and first-sample heatmap. Export ZIP to Files/a computer and inspect all four files. Confirm deleting one capture removes its entire bundle while retaining others. Interrupt/background/resume and check recovered data is labeled correctly. Record AI for five minutes and assess growth, smoothness, memory, and temperature.

All repository documentation and code comments are written in English.
