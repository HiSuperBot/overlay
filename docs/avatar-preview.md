# Human avatar preview

## Frame ownership

`FaceTrackingController` owns the sole `ARSession`, permissions, capture format, and lifecycle. Its main delegate queue delivers each latest `ARFrame` directly to `AvatarFrameDriver`. The latest frame and frame consumer are excluded from Observation; SwiftUI receives state transitions, selections, loading results, and fit readiness rather than per-frame expression dictionaries.

`CameraPreviewHost` retains both a diagnostic MTKView and an ARView. The ARView uses the controller's session with automatic configuration disabled. Original and Mesh use the existing Metal renderer; Avatar uses RealityKit. Inactive renderers are hidden and the MTKView stops drawing while Avatar is active. Session configuration changes without removing anchors when changing capture formats.

ARKit light estimation is enabled, and RealityKit's automatic AR environment lighting consumes the same session's estimates. The USD Preview Surface materials supply skin color, normal, roughness, and opaque eye/teeth surfaces. Real-face mesh occlusion and person occlusion are disabled so they cannot hide the replacement.

## Face selection

The camera footer's **Face** button presents a medium-height SwiftUI sheet that can expand to large. Its two-column grid offers Original, Mesh, and the two catalog avatars. The checkmark uses the preview mode as well as the avatar ID, so a remembered avatar is not shown as active while using Mesh or Original. Selecting a human sets its avatar ID and activates Avatar mode before dismissing; every choice applies immediately. Closing without choosing only dismisses the sheet.

The sheet shares the camera's existing controller and does not own a preview view, session, or lifecycle task. Presentation does not replace the camera host or reset calibration. The current choice, loading and fit status, Re-fit, and error feedback remain on the camera screen. Reopening starts at medium height, and rapid choices use the existing asynchronous loader's cancellation and request token.

## Animation and fitting

The loader verifies that blink, jaw, and named eye entities survived export. Every model mesh with morph data receives `BlendShapeWeightsComponent`; all its named weight sets are updated. Skin, lips, brows, lashes, tongue, teeth, and the closed oral cavity retain applicable expressions. Eye globes instead rotate around their separate anatomical pivots. Facial eye-look targets animate lids while eye globe rotation comes from ARKit's eye transforms.

Expressions are clamped to [0, 1]. Blinks and jaw opening use a 12ms response constant; other expressions use 45ms. Expression updates are capped at 30Hz, while RealityKit controls its own rendering cadence through public APIs. No private frame-rate properties are used.

The calibrator requires valid metric face measurements and one continuous second with a relaxed mouth and open eyes. It averages eye centers and face bounds. The fit blends eye spacing and face width, bounds the vertical ratio relative to eye scale, and translates the model eye midpoint to the measured midpoint. An avatar change solves a new transform against the same measured face. Re-fit and a new AR face anchor discard calibration. Losing the same anchor hides the avatar and interrupts any pending calibration without discarding a completed fit.

Loading uses a cancellation task and monotonically increasing request token. A completed obsolete request cannot mutate the current avatar. Until the latest model and calibration are ready, the compositor shows the original image. Load errors switch the visible renderer to the original camera without stopping the session.

## GPU composition

The tracked triangle mesh contains eye and mouth holes. `FaceOutline` counts triangle edges, walks boundary loops, and selects the longest outer contour. The compositor fills its projected polygon, covering the entire tracked face including real eyes and lips. It renders an R8 mask at half resolution and applies a separable seven-tap feather before mixing the rendered face with the original camera.

Contour vertices and camera image-plane rays are projected with `ARView.project`, so the camera sampling transform and mask use RealityKit's actual viewport crop and front-camera reflection. The diagnostic renderer retains its explicit single reflection. Composition blends in linear RGB and explicitly encodes unorm output through sRGB storage views; HDR rendering is disabled for the first preview. Device checks must confirm matching direction and crop across the two paths.

The Metal postprocess callback reads an immutable frame snapshot protected by a lock. Captured pixel buffers and CVMetalTexture wrappers live until the framework-owned command buffer completes. The callback never commits that buffer. All early exits write the target, and a snapshot older than 150ms gets an empty face mask. Tracking loss, inactivity, and errors disable the avatar anchor and invalidate the mask. The camera's real mouth is also blocked by a closed, animated oral cavity behind the lips.

## Verification limits

The optional standalone macOS importer additionally verifies actual RealityKit morph names, eye pivots, and physically based materials. It does not establish iPhone runtime behavior. The source checks validate the USDZ structure, meter/Y-up metadata, named expressions, neutral weights, texture sizes, triangle budget, and Swift/Metal configuration. They cannot establish skin appearance, iPhone USD import behavior, projection timing, eye alignment, thermal behavior, or measured frame pacing. Follow the README device checklist before accepting visual quality or committing a performance claim.
