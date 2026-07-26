#!/bin/bash
# Bridge the index-store path SwiftPM's BSP server advertises to the one its
# builds actually write.
#
# With `swiftPM.buildSystem: "swiftbuild"` (see .sourcekit-lsp/config.json),
# sourcekit-lsp asks `swift package experimental-build-server` where the index
# store is. On Swift 6.4 that server answers `.build/index-store`, but the
# swiftbuild engine passes `-index-store-path .build/out` when it compiles — so
# sourcekit-lsp opens an empty store and every reference query returns nothing.
# Symlinking the advertised path at the real one makes them agree.
#
# Re-run after anything that removes .build (a clean, or a fresh worktree).
set -euo pipefail
cd "$(dirname "$0")/.."          # -> app/Modules
if [ -L .build/index-store ]; then
  echo "already linked: .build/index-store -> $(readlink .build/index-store)"
  exit 0
fi
if [ ! -d .build/out ]; then
  echo "no .build/out yet — run 'swift build' first, then re-run this." >&2
  exit 1
fi
rm -rf .build/index-store
ln -s out .build/index-store
echo "linked .build/index-store -> out ($(ls .build/index-store/v5/units | wc -l | tr -d ' ') units)"
