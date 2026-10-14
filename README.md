# Overlay

A project hub for camera and face-overlay experiences. The native iOS app lives in `apps/ios`.

## iOS app

Open `apps/ios/Overlay.xcodeproj` in Xcode and select the `Overlay` scheme.

- SwiftUI interface, ARKit face tracking, and Metal rendering.
- iOS 18 or later, portrait orientation, and one tracked face.
- A physical iPhone with a supported TrueDepth front camera is required for the live preview.
- Bundle identifier: `com.mindware.Overlay`.

The preview displays a mirrored front-camera feed with a white face wireframe. The mesh follows head movement and facial expressions. A switch hides the mesh while keeping the camera running. Tracking loss hides the mesh until the face is found again.

The app handles camera permission, unsupported devices, session interruptions, and recoverable session errors. Camera capture pauses when the app becomes inactive. No camera frames or face-tracking data are saved or transmitted.

Photo capture, video recording, character models, and avatar animation are outside this first version.

## Repository layout

```text
apps/ios/
├── Overlay.xcodeproj/
└── Overlay/
    ├── App/                 # Application entry point
    ├── Features/Camera/     # Camera screen and SwiftUI/Metal view bridge
    ├── Tracking/            # Permissions, ARSession, and tracking state
    ├── Rendering/           # Camera compositor, face mesh renderer, and shaders
    └── Resources/           # Bundled app assets
```

Add shared design documents under `docs/` and source character models or textures under `assets/` when needed.

## Run

If Xcode reports that the Metal Toolchain is missing, install Apple's compiler component before building:

```sh
xcodebuild -downloadComponent MetalToolchain
```

For a physical iPhone:

1. Select your Apple development team under **Signing & Capabilities**.
2. Select your connected TrueDepth iPhone as the run destination.
3. Build and run, then allow camera access.

The simulator displays the interface and a device requirement message. It cannot validate TrueDepth capture, face tracking, or mesh alignment.

Run builds and device tests manually as needed. The repository's development workflow prioritizes source changes over automatically starting simulator sessions or repeatedly rebuilding.

An optional simulator build command:

```sh
xcodebuild -project apps/ios/Overlay.xcodeproj -scheme Overlay \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/overlay-derived-data build
```

## Device test checklist

- Allow camera access: the live preview appears and the status changes to **Face tracked**.
- Blink, open your mouth, turn your head, and move closer or farther away: the white mesh follows the eyes, nose, lips, and chin.
- Check the mirrored preview: the video and mesh stay aligned on both sides of the face.
- Turn **Face mesh** off and on: the camera continues running.
- Move out of view and return: the mesh disappears, then tracking resumes.
- Background the app and return: the preview resumes without stale face geometry.
- Deny camera access: the app explains the requirement and provides **Open Settings**.
- Run in the simulator: the device requirement message appears without starting an AR session.

## Rendering

Each render uses one `ARFrame` for both the camera image and face geometry. The camera image's inverse display transform and the camera projection use the same portrait viewport. Mirroring applies to the composed preview, so the image and mesh receive the same horizontal flip.

The renderer reuses three vertex buffers and a static triangle index buffer. A depth-only face pass hides wireframe edges behind the visible facial surface. At most three GPU commands are in flight; the renderer skips a draw rather than waiting for an occupied buffer. Rendering targets up to 60 fps when a suitable TrueDepth capture format is supported; actual performance must be checked on the test iPhone.

All repository documentation is written in English.
