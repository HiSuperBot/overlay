# Recording architecture

## Capture and UI

`RecordingController` owns the observable state machine: idle → preparing → recording → finishing → saving → idle. Preparing includes permission prompts, a fresh camera frame/fit check, off-main encoder setup, and waiting for the first encoded frame. Duplicate starts/stops are ignored. SwiftUI observes state transitions and a one-second elapsed-time update, not individual video or audio samples. The red circle becomes a stop square while recording. The control row has a fixed height; feedback overlays the preview.

The existing `FaceTrackingController` remains the only camera-session owner. Starting capture changes its configuration to a supported 30fps format and enables ARKit audio delivery, without resetting tracking or removing anchors. Ending capture disables audio and restores the idle mode's frame-rate preference. Microphone permission is requested through `AVAudioApplication`; Photos uses `.addOnly`, never library read access. The app configures the audio session for video recording and restores its previous category/mode after capture.

Permission dialogs may make the scene inactive before recording starts. Preparation tolerates those dialogs and waits for the resumed session's first frame; actual backgrounding cancels it. Once a recorder is active, losing foreground, camera availability, microphone availability, or avatar/Metal rendering automatically stops it. Face-tracking loss alone leaves recording active and captures the preview's original-camera fallback. A recording never automatically restarts after an interruption.

## Final pixels and time

`CameraPreviewHost` gives both renderers a stable `RecordingFrameSink`. The diagnostic renderer submits its drawable after the camera and mesh passes. Its drawable is shader-readable, and `Recording.metal` bakes the diagnostic UIView's reflection into the exported pixels. `AvatarCompositor` submits the final target after its postprocess encoding, including valid camera passthrough frames. The shared recording shader resizes to fixed even dimensions within 1080 × 1920, encodes linear/sRGB texture sampling to sRGB storage, and forces opaque output. H.264 color metadata declares sRGB transfer and BT.709 primaries/matrix. UI elements are never part of those textures.

The output dimensions and preview aspect are fixed when preparation starts. The host keeps that aspect if its available layout changes during capture. No second camera session, screen capture, UIKit snapshot loop, or CPU pixel readback is used.

`MovieRecorder` prepares AVAssetWriter, an adaptor-provided IOSurface/Metal-compatible BGRA pool, H.264 video, and mono 48kHz AAC on a detached setup task. Each frame copy is encoded into the renderer's existing command buffer. RealityKit owns and commits its own buffer. Only GPU completion can enqueue the corresponding video for encoding; retained Core Video texture wrappers survive GPU access.

The admission lock protects stopping, capture timestamps, and sequence tickets. A nonblocking three-slot limit bounds video work; the pool also has an allocation threshold. Sixteen audio queue slots and at most 32 pre-video audio samples bound microphone retention. If encoding falls behind, samples are dropped without blocking the preview. GPU completions are reordered by admission sequence on the serial writer queue. A group entry is released only after that frame has been appended or deliberately skipped, so finishing waits for all admitted GPU work.

Video uses `ARFrame.timestamp`; audio uses the sample buffer presentation timestamp in ARKit's host-clock capture domain. The first written video frame starts the writer session. Audio preceding that point and nonnumeric/nonincreasing timestamps are discarded. Repeated camera frames and input rates above 30fps are gated. Capture gaps retain their elapsed time. A clock-domain discrepancy or absent video/audio after three seconds stops capture with an explanation. Finish ends the session at the last written frame plus one frame interval, bounding audio overhang. A valid clip with unavailable audio can still be preserved and saved, with an explicit no-sound notice.

## File lifetime and saving

In-progress MP4s use a `writing-` prefix in `Application Support/Recordings`; this directory is excluded from backups. A successfully finalized file is moved to its completed name and recorded in an atomic pending-file manifest before Photos saving. A rename failure keeps the finalized file at its original path. Photos completion is awaited before deleting any completed local video. Saving failure retains the file and offers Retry save and Share; sharing alone does not remove the recovery copy.

At launch, the manifest restores pending files and completed files missing from the manifest are recovered. Abandoned `writing-` files are inspected: finalized playable clips are recovered, confirmed empty/unplayable files are removed, and files whose metadata cannot be loaded are retained. This also protects a completed clip if termination happens before its rename. Pending clips can be saved together by Retry save or after the next completed recording. This is recovery storage, not a video gallery.

Stopping obtains a finite UIKit background task to drain GPU/encoder work and save. Expiration ends that task; the operating system still controls whether work can finish before suspension or termination. Background capture is not enabled. Empty clips and unusable writer output produce an error and remove their incomplete file.

## Validation

`scripts/check_sources.sh` type-checks all iOS sources, compiles the Metal kernels, checks both build configurations' camera/microphone/add-only Photos descriptions, and tests dimensions and frame admission. Its optional `--recording` check uses the actual shader and movie writer to generate synthetic MP4s on macOS, then decodes them to verify H.264/AAC tracks, fixed dimensions, near-zero start time, audio alignment, monotonic timestamps, reflected colors, mid-gray brightness, and draining on immediate stop. It also rejects an empty recording and checks completed-file recovery before/after manifest writing. No camera/session or app window is created.

TrueDepth/RealityKit output, actual ARKit microphone timing, Photos permissions/transactions, scene/audio interruptions, and sustained thermal performance require the manual iPhone checklist in the root README. Full Xcode builds and device runs remain user-operated.
