# Avatar source assets

Human A and Human B are adult, face-only MakeHuman characters prepared with MPFB 2.0.18 and Blender 5.2.0 LTS. The editable, texture-packed sources are in `source/`. Runtime USDZ files, 256px thumbnails, and the catalog are in `../../apps/ios/Overlay/Resources/Avatars/`.

## Provenance and licensing

All character input data used here is CC0 1.0 Universal. The full asset license is preserved in [CC0-1.0.txt](CC0-1.0.txt). Archive URLs and SHA-256 digests are pinned in [sources.json](sources.json).

| Input | Source | License evidence |
| --- | --- | --- |
| Base mesh and adult phenotype targets | [MPFB 2.0.18](https://github.com/makehumancommunity/mpfb2/tree/v2.0.18/src/mpfb/data) | [MPFB asset license](https://github.com/makehumancommunity/mpfb2/blob/v2.0.18/LICENSE.ASSETS.md) |
| Human A albedo: `young_asian_male` | [MakeHuman system asset pack](https://static.makehumancommunity.org/assets/assetpacks/makehuman_system_assets.html) | CC0 pack; source MHMAT header |
| Human B albedo: `young_caucasian_female` | Same system asset pack | CC0 pack; source MHMAT header |
| High-poly eyes; brown and green eye maps | Same system asset pack | CC0 pack; source MHCLO/MHMAT headers |
| `eyebrow001`, `eyelashes01`, `teeth_base`, `tongue01` | Same system asset pack | CC0 pack; source MHCLO/MHMAT headers |
| 52 ARKit expression targets | [faceunits01](https://static.makehumancommunity.org/assets/assetpacks/faceunits01.html), pack contributor Mika Suominen | [extra-targets repository CC0 license](https://github.com/makehumancommunity/extra-targets/blob/master/LICENSE) |
| Pore normals, roughness maps, closed oral cavity | Authored by this repository's conversion script | CC0 derivatives and generated data |

The original system asset notices name Data Collection AB, Joel Palmius, and Jonas Hauquier (2020). MPFB is used as a build-time authoring tool; its GPL program code and Blender are not bundled in the iOS app. See [MakeHuman's licensing explanation](https://static.makehumancommunity.org/about/license.html) for the distinction between tool code and exported assets.

## Reproduce

Run from the repository root on macOS with Blender 5.2 and Apple's `usdcat`/`usdzip` available:

```sh
python3 assets/avatars/scripts/fetch_sources.py
BLENDER_USER_RESOURCES="$PWD/assets/avatars/.cache/blender-user" \
  /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
  --python-exit-code 1 --python assets/avatars/scripts/build_avatars.py
python3 assets/avatars/scripts/validate_avatars.py
```

The source downloads total approximately 310 MB and stay in the ignored `.cache/` directory. The script never loads or changes a user's existing Blender scene or saves add-on preferences. It adapts MPFB's extension path provider inside the isolated process.

The pipeline bakes adult phenotype targets, loads system body parts, transfers faceunits to brows, lashes, teeth, and tongue through MPFB's MHCLO interpolation, and removes the body, scalp above the useful forehead, and back of the head. A subdivision pass followed by neutral-surface decimation retains a fixed topology and all 52 facial deltas. Degenerate surface correspondences fall back to a nearest corner. The separate eye meshes retain anatomical pivots and do not have morph targets.

The assets use meters, +Y up, +Z toward the viewer, and an origin halfway between the eyes. USD metadata is set explicitly after baking that coordinate transform. `source/*.json` reports triangle counts, expression names, and neutral fit metadata. USDZ packages retain the USD skeleton and blend shape bindings required by RealityKit.

The skin albedo comes from the core pack. Normal and roughness maps are subtle procedural derivatives, not scanned skin detail. The first version establishes a human face replacement pipeline; likeness, skin detail, eye realism, and boundary alignment still require review on a TrueDepth iPhone. There are no hair or body meshes, and no automatic glasses, hands, or bangs occlusion.
