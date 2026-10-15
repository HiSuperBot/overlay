# AI capture and bundle format v1

## Camera behavior

The two camera modes are independent of face effects, and both show the selected Original/Mesh/avatar effect before recording. **Video** saves composited H.264/AAC footage to Photos. **AI** displays the same effect but stores original camera H.264/AAC footage and depth in the app. Video is the initial mode; the last selected camera mode and avatar ID are persisted separately. A previously saved Preview mode is migrated to Video.

`RecordingController` owns preparation, recording, finishing, and saving for both destinations. Mode/face changes, avatar retry, Re-fit, and the AI library are locked while capture is busy. AI preparation requests microphone access, applies the existing session's 30fps preference, and waits up to three seconds for a fresh frame in that format with TrueDepth data and a ready preview. It does not request Photos access or invoke the PhotoKit saving path. The normal recording frame sink remains inactive in AI mode.

`FaceTrackingController.captureFrameConsumer` supplies a separate original-data subscriber after the avatar driver. `ARFrameAICapture` snapshots color/depth buffer references, native intrinsics, and available calibration; it never retains a mutable face anchor. `AICaptureRecorder` has no Metal, UIKit, or Photos dependency. A bounded three-frame serial queue writes the original `capturedImage` through AVAssetWriter and writes its associated depth/index data. Backpressure drops an entire sensor pair; rejected video never leaves an orphan depth block. Repeated, backward, nonfinite, and over-rate RGB timestamps are gated. The first recorded frame must contain depth; later missing depth is explicitly recorded.

The original video uses the source dimensions and YUV buffer, with H.264 High profile, no frame reordering, and a bitrate of at least 8 Mbps or `width × height × 30 × 0.18` bits/second. Source color attachments are carried into encoding. No avatar pixels, viewport crop, pixel rotation, resizing, or display reflection are applied. A portrait preferred transform derived from ARKit, with reflection removed, is stored in the movie and manifest. The encoded pixel coordinates therefore remain the camera's native coordinates. Mono 48kHz AAC uses the same ARKit audio stream as Video mode. Missing audio stops startup and produces an incomplete capture rather than a successful silent AI capture.

## Package layout

Each capture lives in `Application Support/AICaptures/<UUID>/`, excluded from backups. It contains:

| File | Content |
| --- | --- |
| `video.mp4` | Original camera video plus microphone audio; portrait playback metadata |
| `depth.bin` | Consecutive native floating-point maps, with row padding removed |
| `frames.jsonl` | One compact JSON line per committed RGB frame and its optional depth block |
| `manifest.json` | Versioned metadata and atomically updated recording/completion state |

`manifest.json` declares `schemaVersion: 1`, UUID, UTC ISO-8601 creation date, status (`recording`, `complete`, `interrupted`, `incomplete`), source video dimensions/pixel format, six preferred-transform values `[a,b,c,d,tx,ty]`, selected preview effect, codecs, 30fps target, byte/matrix order, source clock, optional start timestamp, duration, video/depth/missing/drop counts, audio availability, and an optional stop explanation. Counts refer to the committed frame index. A depth sample on an accepted RGB frame is counted once; missing depth is not replaced with a previous sample.

Each `frames.jsonl` object contains `index`, original RGB `timestamp`, normalized `videoTime`, nine row-major `rgbIntrinsics` values in native RGB pixel coordinates, `depthMissing`, and optional `depth`. The first RGB timestamp is the common time origin. RGB timestamps and depth timestamps remain independent; a depth sample can precede the first RGB sample and consequently have a negative relative time. Camera/depth capture timestamps come from ARKit's capture stream. The UI elapsed timer is independent of the serialized sensor data.

The depth object contains original `timestamp`, `relativeTimestamp`, `byteOffset`, `byteLength`, width/height, numeric Core Video `pixelFormat`, named `format`, `unit`, `filtered`, numeric AVDepthData quality/accuracy, optional `calibration`, and `calibrationMissing`. Optional properties absent from JSON are unavailable, not identity transforms or zero measurements.

Depth formats are `depthFloat16`, `depthFloat32`, `disparityFloat16`, and `disparityFloat32`. Values are IEEE-754, little-endian, tightly packed row-major with the sensor's top-left origin. Depth units are `meters`; disparity units are `inverseMeters`. The length is `width × height × (2 or 4)`. NaNs, infinities, signed zeros, and NaN payload bits are retained exactly. Neither system-filtered maps nor holes are changed by the app. The `filtered` flag describes the sensor pipeline's supplied map, not an app filter.

Calibration, when supplied, includes a row-major 3×3 intrinsic matrix, its reference dimensions, a row-major 3×4 extrinsic matrix whose translation remains in **millimeters**, pixel size in millimeters, distortion center, and available radial distortion/inverse-distortion Float32 tables. Depth and RGB may have different resolutions. Apply reference-dimension scaling and lens calibration when reconstructing geometry; the stored data is not rectified. The first-sample heatmap converts disparity to distance only for display and does not modify the package.

## Finalization, recovery, and storage

The writer takes the first accepted RGB timestamp as AVAssetWriter's session origin. Audio before that point is discarded; initial audio retention is bounded to 32 samples and its writer queue to 16 slots. Audio/video clock discrepancies stop capture. Stop closes admission under the same lock used to enqueue input, then drains all previously admitted work. Depth bytes are written before the corresponding JSON line; a failed sidecar write rolls both handles back to their last committed offsets. Finishing synchronizes and closes sidecars, ends the video at the last committed frame plus one interval, and finalizes the MP4. One-second movie fragments improve the availability of footage after interruptions but do not guarantee recovery after force termination.

Completion requires a finalized playable video covering the indexed capture interval, committed RGB and depth, audio, and a consistent journal. The manifest is written atomically after output finalization, then the store validates the journal and video before exposing the result. User stops become Complete; ordinary lifecycle stops with valid data become Interrupted; missing or inconsistent data is Incomplete. The store retains incomplete bundles for review/export/deletion rather than silently discarding depth. At relaunch it scans Recording bundles, preserves complete indexed depth blocks, trims unindexed binary/partial JSON tails, and never labels a depth-free recording Complete. If a surviving movie fragment is shorter than its index, the package is Incomplete and all committed sensor records are kept; consumers can use `manifest.duration` to identify the playable interval. An MP4 the OS terminated before enough finalization may remain unplayable; available sidecars can still be exported.

Start requires 512 MiB of available capacity. A two-second monitor stops capture below a 256 MiB reserve, and export checks room for a temporary archive plus that reserve. Capacity samples and capacity-trigger details remain in the app's UI; packages record a generic interruption. Leaving the foreground, camera/audio interruption, route loss, rendering failure, or I/O failure stops recording; capture does not restart automatically. UIKit provides finite background time to finalize, with OS-controlled suspension/termination limits.

AI storage is separate from normal pending PhotoKit movies. Completing an AI capture does not save earlier pending normal videos, and Photos recovery does not scan AI bundles. Mode changes clear stale permission feedback; the PhotoKit retry action is available only in Video mode.

## Library and export

**AI Captures** opens a dark library with date, duration, size, status, and depth counts. Details play the original video and show audio availability, missing depth/dropped pairs, first depth resolution/format, calibration availability, and a first-sample heatmap. A confirmation deletes the entire selected bundle. The preview/camera session is not recreated to open the library.

Export creates `<UUID>/video.mp4`, `depth.bin`, `frames.jsonl`, and `manifest.json` entries in ZIP, keeping every available source file byte-for-byte. MP4 entries are stored; other entries use lossless Deflate. Incomplete packages include the available files and status metadata. Export runs off the main actor and leaves the source untouched. Temporary archives are removed after sharing or at the next app launch. The store prevents deletion during export and propagates cancellation to ZIP work.

[ZIPFoundation 0.9.20](https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.20) is pinned to revision `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` through Swift Package Manager. Its MIT license is included in `Resources/Licenses/ZIPFoundation.txt`, and the package supplies its own privacy resource. The app's privacy manifest describes local storage capacity checks, container metadata, elapsed timers, and app-owned preferences using [Apple's required-reason declarations](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons).

## Validation

Run `./scripts/check_sources.sh --recording --ai` for iOS source/Metal/project checks, the existing avatar/calibration tests, composited movie regressions, and original-data tests. The first source check obtains the pinned ZIPFoundation source in a temporary cache and emits dependency modules for type checking; it does not build the app. `OVERLAY_ZIPFOUNDATION_SOURCE` can point at an existing checkout of the same pinned revision. All generated test movies/modules/archives remain in temporary directories.

AI checks generate an original NV12 movie and synthetic AAC/depth, decode the H.264 pixels, verify native dimensions/orientation, all four depth bit representations and padded-row removal, separate RGB/depth times, missing samples/calibration, journal consistency under burst backpressure, stop draining, ZIP equality, relaunch repair, missing-depth status, bundle deletion, and storage rejection. AI data service imports are checked for PhotoKit separation.

Device validation remains necessary: select every face effect in AI mode, confirm the saved footage shows the original face while live preview uses the selected effect, confirm no Photos permission/save occurs, inspect measured depth/calibration and gaps, test library/export/delete, background/microphone interruptions, and assess five-minute speed, size, memory, and temperature. Full Xcode builds, package resolution in Xcode, and device runs are user-operated. No model inference or upload is part of this version.
