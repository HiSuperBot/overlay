# Overlay

A project hub for camera and face-overlay experiences. The native iOS app lives in `apps/ios`.

The camera preview offers **Original**, **Mesh**, and **Avatar** modes. Avatar mode replaces the tracked face with **Human A** or **Human B**, including animated eyes, lips, brows, lashes, teeth, and mouth interior. A feathered face mask keeps the camera's hair, neck, body, and background outside the replacement region.

Tap **Face** in the camera footer to open a bottom sheet with **Original**, **Mesh**, **Human A**, and **Human B** cards. The current choice has a checkmark. Selecting a card immediately applies it and closes the sheet; closing or dragging the sheet down without selecting keeps the current effect. The sheet starts at medium height and can expand. Camera capture and face calibration continue while it is open. Loading, fit status, **Re-fit**, and error feedback remain on the camera screen.

- iOS 18 or later, portrait orientation, one face, and a supported TrueDepth front camera.
- One ARKit capture session shared by Metal and RealityKit.
- A supported 30fps capture format in Avatar mode; faster diagnostic capture where available.
- An initial continuous neutral second fits the face. **Re-fit** repeats calibration; avatar changes reuse the measurements.
- Asynchronous local model loading with the last selection winning. Human A is the initial default and the selected avatar ID is saved.
- Original-camera fallback and an error message when an avatar cannot load.
- All capture, tracking, loading, and rendering run on the iPhone. Frames and tracking data are not saved or transmitted.

Hands, glasses, and bangs can currently be covered if they enter the face mask. Full head replacement, photos, and video recording are outside this version. Actual preview speed, temperature, expression fidelity, and alignment require device validation.

## Repository layout

```text
assets/avatars/              # Editable Blender sources, conversion scripts, licenses
apps/ios/
├── Overlay.xcodeproj/
└── Overlay/
    ├── App/                 # Application entry point
    ├── Avatars/             # Catalog, expression mapping, calibration, frame driver
    ├── Features/Camera/     # SwiftUI screen and shared preview host
    ├── Tracking/            # Permissions, ARSession, frame delivery, camera state
    ├── Rendering/           # Diagnostic renderer, avatar compositor, Metal shaders
    └── Resources/Avatars/   # Two USDZ models, thumbnails, catalog
scripts/check_sources.sh     # Lightweight checks; never starts Xcode or a simulator
tests/                      # Standalone Swift unit tests
docs/                       # Rendering architecture and device checks
```

See [avatar provenance and reproduction](assets/avatars/README.md) and [rendering architecture](docs/avatar-preview.md).

## Run

Open `apps/ios/Overlay.xcodeproj` in Xcode and select the **Overlay** scheme (bundle ID `com.mindware.Overlay`). Select your development team under **Signing & Capabilities**, choose your connected TrueDepth iPhone, build and run, and allow camera access. A Personal Team can be used for development testing.

If Xcode reports a missing Metal Toolchain, install Apple's compiler component:

```sh
xcodebuild -downloadComponent MetalToolchain
```

The simulator displays the interface and a device requirement message. It cannot validate TrueDepth, facial expressions, or face replacement. Full builds, simulator sessions, and device runs are performed manually in this repository.

## Lightweight validation

```sh
./scripts/check_sources.sh
```

This type-checks Swift against the iOS 18 deployment target, compiles Metal shaders, checks the project and packaged assets, and runs standalone Swift tests for calibration, face fitting, expression mapping, and hole-free contour selection. Outputs stay in a temporary directory. It does not build or run the app. To also check actual RealityKit USDZ import on macOS 15 or later, use `./scripts/check_sources.sh --realitykit`. This optional standalone asset check verifies 52 imported expressions, separate eye pivots, and PBR materials without creating a camera session or window.

## Device checklist

1. Tap **Face**: the sheet starts at medium height, expands, and closes with its close button or a downward drag. Keep the sheet open and confirm the camera remains live. Dismiss without selecting and confirm the effect and completed fit are retained.
2. Select each of **Original**, **Mesh**, **Human A**, and **Human B**. Each selection closes the sheet and updates the footer name. Reopen it and verify only the current choice is checked. Switch directly from Mesh to each human face.
3. In Avatar mode, look straight ahead and relax your face for one second. Blink, speak, and move your gaze. Try **Re-fit**. Rapidly reopen the sheet and switch avatars; verify the last selection wins.
4. Check frontal and approximately ±30° head turns for exposed real eyes/mouth, gaps, or large boundary offsets. Check that Avatar and Mesh have the same mirrored direction and crop.
5. Confirm hair, neck, body, and background remain camera pixels outside the feathered boundary.
6. Leave the frame and return. Background and resume the app with the selector open, then make another selection. Check for black output or an old face.
7. Use Avatar for five minutes and assess smoothness and temperature. A 30fps capture target is not a measured performance guarantee.
8. Deny camera permission and verify **Open Settings**. Verify the simulator's unsupported-device message.

All repository documentation and code comments are written in English.
