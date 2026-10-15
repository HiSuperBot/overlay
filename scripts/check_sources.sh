#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
check_output=$(mktemp -d /tmp/overlay-check.XXXXXX)
trap 'rm -rf "$check_output"' EXIT
sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
source_files=("${(@f)$(rg --files apps/ios/Overlay -g '*.swift')}")
zip_source_dir=$(zsh scripts/zipfoundation_sources.sh)
zip_sources=("${(@f)$(rg --files "$zip_source_dir/Sources/ZIPFoundation" -g '*.swift')}")
xcrun swiftc -emit-module -parse-as-library -swift-version 5 -module-name ZIPFoundation \
  -sdk "$sdk_path" -target arm64-apple-ios18.0 -module-cache-path "$check_output/modules" \
  "${zip_sources[@]}" -emit-module-path "$check_output/ZIPFoundation.swiftmodule"
# Actor-transfer diagnostics run during SIL generation, after the basic type-checking phase.
xcrun swiftc -emit-sil -whole-module-optimization -o /dev/null -warnings-as-errors \
  -swift-version 5 -strict-concurrency=complete -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature InferSendableFromCaptures \
  -enable-upcoming-feature DisableOutwardActorInference \
  -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
  -sdk "$sdk_path" -target arm64-apple-ios18.0 \
  -I "$check_output" -module-cache-path "$check_output/modules" "${source_files[@]}"
print 'PASS: iOS Swift source and strict concurrency checks (warnings as errors)'
for shader in apps/ios/Overlay/Rendering/*.metal; do
  xcrun --sdk iphoneos metal -c "$shader" -o "$check_output/${shader:t:r}.air"
done
print 'PASS: Metal shaders'
plutil -lint apps/ios/Overlay.xcodeproj/project.pbxproj
plutil -lint apps/ios/Overlay/PrivacyInfo.xcprivacy
python3 assets/avatars/scripts/validate_avatars.py
xcrun swiftc -swift-version 5 \
  apps/ios/Overlay/Avatars/AvatarDescriptor.swift \
  apps/ios/Overlay/Avatars/AvatarMath.swift \
  tests/FaceMaskFixtures.swift tests/AvatarMathTests.swift -o "$check_output/avatar-tests"
"$check_output/avatar-tests"
xcrun swiftc -parse-as-library -swift-version 5 \
  apps/ios/Overlay/Recording/RecordingMath.swift \
  tests/RecordingMathTests.swift -o "$check_output/recording-math-tests"
"$check_output/recording-math-tests"
python3 - <<'PY'
from pathlib import Path
import json
import plistlib
import subprocess
project = Path('apps/ios/Overlay.xcodeproj/project.pbxproj').read_text()
for key in ('NSCameraUsageDescription', 'NSMicrophoneUsageDescription', 'NSPhotoLibraryAddUsageDescription'):
    assert project.count('INFOPLIST_KEY_' + key + ' = ') == 2, key + ' must be present in Debug and Release'
print('PASS: camera, microphone, and add-only Photos descriptions in both configurations')
pins = json.loads(Path('apps/ios/Overlay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())['pins']
assert pins[0]['state'] == {'revision': '22787ffb59de99e5dc1fbfe80b19c97a904ad48d', 'version': '0.9.20'}
project_data = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', 'apps/ios/Overlay.xcodeproj/project.pbxproj']))
packages = [value for value in project_data['objects'].values() if value.get('isa') == 'XCRemoteSwiftPackageReference']
assert any(p['repositoryURL'] == 'https://github.com/weichsel/ZIPFoundation.git' and p['requirement'] == {'kind': 'exactVersion', 'version': '0.9.20'} for p in packages)
assert Path('apps/ios/Overlay/Resources/Licenses/ZIPFoundation.txt').read_text().startswith('MIT License')
privacy = plistlib.loads(Path('apps/ios/Overlay/PrivacyInfo.xcprivacy').read_bytes())
assert any(p['NSPrivacyAccessedAPIType'] == 'NSPrivacyAccessedAPICategoryDiskSpace' and 'E174.1' in p['NSPrivacyAccessedAPITypeReasons'] for p in privacy['NSPrivacyAccessedAPITypes'])
for source in Path('apps/ios/Overlay/AICapture').glob('*.swift'):
    assert 'import Photos' not in source.read_text(), 'AI data services must not depend on PhotoKit'
print('PASS: pinned ZIP dependency/license, storage API description, and AI service PhotoKit separation')
PY
if [[ " ${*} " == *" --realitykit "* ]]; then
  host_arch=$(uname -m)
  xcrun swiftc -parse-as-library -target "$host_arch-apple-macos15.0"     tests/RealityKitAssetTests.swift -o "$check_output/asset-tests"
  "$check_output/asset-tests" apps/ios/Overlay/Resources/Avatars/*.usdz
fi
if [[ " ${*} " == *" --avatar-mask "* ]]; then
  xcrun --sdk macosx metal -c apps/ios/Overlay/Rendering/AvatarComposite.metal -o "$check_output/avatar.air"
  xcrun --sdk macosx metallib "$check_output/avatar.air" -o "$check_output/avatar.metallib"
  host_arch=$(uname -m)
  xcrun swiftc -parse-as-library -swift-version 5 -target "$host_arch-apple-macos15.0" \
    apps/ios/Overlay/Avatars/AvatarDescriptor.swift apps/ios/Overlay/Avatars/AvatarMath.swift \
    tests/FaceMaskFixtures.swift tests/AvatarMaskTests.swift -o "$check_output/avatar-mask-tests"
  "$check_output/avatar-mask-tests" "$check_output/avatar.metallib"
fi
if [[ " ${*} " == *" --recording "* ]]; then
  xcrun --sdk macosx metal -c apps/ios/Overlay/Rendering/Recording.metal -o "$check_output/recording.air"
  xcrun --sdk macosx metallib "$check_output/recording.air" -o "$check_output/recording.metallib"
  host_arch=$(uname -m)
  xcrun swiftc -parse-as-library -swift-version 5 -target "$host_arch-apple-macos15.0" \
    apps/ios/Overlay/Recording/RecordingMath.swift \
    apps/ios/Overlay/Recording/MovieRecorder.swift \
    apps/ios/Overlay/Recording/RecordingRecovery.swift \
    tests/MovieRecorderTests.swift -o "$check_output/movie-tests"
  "$check_output/movie-tests" "$check_output/recording.metallib" "$check_output/clips"
fi
if [[ " ${*} " == *" --ai "* ]]; then
  mkdir -p "$check_output/zip-mac"
  host_arch=$(uname -m)
  xcrun swiftc -emit-library -emit-module -parse-as-library -swift-version 5 \
    -target "$host_arch-apple-macos15.0" -module-name ZIPFoundation "${zip_sources[@]}" \
    -o "$check_output/zip-mac/libZIPFoundation.dylib" \
    -emit-module-path "$check_output/zip-mac/ZIPFoundation.swiftmodule"
  xcrun swiftc -parse-as-library -swift-version 5 -target "$host_arch-apple-macos15.0" \
    -I "$check_output/zip-mac" -L "$check_output/zip-mac" -lZIPFoundation \
    -Xlinker -rpath -Xlinker "$check_output/zip-mac" \
    apps/ios/Overlay/Recording/RecordingMath.swift \
    apps/ios/Overlay/AICapture/AICaptureFormat.swift \
    apps/ios/Overlay/AICapture/AICaptureFrame.swift \
    apps/ios/Overlay/AICapture/AICaptureJournal.swift \
    apps/ios/Overlay/AICapture/AICaptureRecorder.swift \
    apps/ios/Overlay/AICapture/AICaptureStore.swift \
    apps/ios/Overlay/AICapture/AIDepthVisualization.swift \
    tests/SyntheticCapture.swift tests/AICaptureTests.swift -o "$check_output/ai-tests"
  "$check_output/ai-tests" "$check_output/ai-captures"
fi
git diff --check
