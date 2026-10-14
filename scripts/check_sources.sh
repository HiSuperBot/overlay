#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
check_output=$(mktemp -d /tmp/overlay-check.XXXXXX)
trap 'rm -rf "$check_output"' EXIT
sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
source_files=("${(@f)$(rg --files apps/ios/Overlay -g '*.swift')}")
xcrun swiftc -typecheck -swift-version 5 -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -sdk "$sdk_path" -target arm64-apple-ios18.0 \
  -module-cache-path "$check_output/modules" "${source_files[@]}"
print 'PASS: iOS Swift source type check'
for shader in apps/ios/Overlay/Rendering/*.metal; do
  xcrun --sdk iphoneos metal -c "$shader" -o "$check_output/${shader:t:r}.air"
done
print 'PASS: Metal shaders'
plutil -lint apps/ios/Overlay.xcodeproj/project.pbxproj
python3 assets/avatars/scripts/validate_avatars.py
xcrun swiftc -swift-version 5 \
  apps/ios/Overlay/Avatars/AvatarDescriptor.swift \
  apps/ios/Overlay/Avatars/AvatarMath.swift \
  tests/AvatarMathTests.swift -o "$check_output/avatar-tests"
"$check_output/avatar-tests"
xcrun swiftc -parse-as-library -swift-version 5 \
  apps/ios/Overlay/Recording/RecordingMath.swift \
  tests/RecordingMathTests.swift -o "$check_output/recording-math-tests"
"$check_output/recording-math-tests"
python3 - <<'PY'
from pathlib import Path
project = Path('apps/ios/Overlay.xcodeproj/project.pbxproj').read_text()
for key in ('NSCameraUsageDescription', 'NSMicrophoneUsageDescription', 'NSPhotoLibraryAddUsageDescription'):
    assert project.count('INFOPLIST_KEY_' + key + ' = ') == 2, key + ' must be present in Debug and Release'
print('PASS: camera, microphone, and add-only Photos descriptions in both configurations')
PY
if [[ " ${*} " == *" --realitykit "* ]]; then
  host_arch=$(uname -m)
  xcrun swiftc -parse-as-library -target "$host_arch-apple-macos15.0"     tests/RealityKitAssetTests.swift -o "$check_output/asset-tests"
  "$check_output/asset-tests" apps/ios/Overlay/Resources/Avatars/*.usdz
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
git diff --check
