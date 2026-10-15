#!/bin/zsh
set -euo pipefail
zip_source_dir="${OVERLAY_ZIPFOUNDATION_SOURCE:-${TMPDIR:-/tmp}/overlay-zipfoundation-0.9.20}"
if [[ ! -d "$zip_source_dir/.git" ]]; then
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch 0.9.20 \
    https://github.com/weichsel/ZIPFoundation.git "$zip_source_dir" >&2
fi
zip_revision=$(git -C "$zip_source_dir" rev-parse HEAD)
if [[ "$zip_revision" != 22787ffb59de99e5dc1fbfe80b19c97a904ad48d ]]; then
  print -u2 'ZIPFoundation source revision does not match the pinned 0.9.20 release.'
  exit 1
fi
print -r -- "$zip_source_dir"
