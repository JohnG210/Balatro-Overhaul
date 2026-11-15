#!/usr/bin/env bash
# Stage tools/release/ios/build/src from public, pinned sources.
# Nothing from Balatro is fetched.
#   LOVE 11.5 iOS source + apple libraries: release assets of
#     https://github.com/love2d/love/releases/tag/11.5  (sha256 in ../SHA256SUMS)
# The Overhaul itself is this repository.
# usage: tools/release/ios/scripts/fetch_sources.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/build/src"
base=https://github.com/love2d/love/releases/download/11.5
mkdir -p "$src"
cd "$src"
cp "$root/SHA256SUMS" SHA256SUMS
for f in love-11.5-ios-source.zip love-11.5-apple-libraries.zip; do
  if [ ! -f "$f" ]; then
    curl -fL --retry 3 -o "$f.part" "$base/$f"
    mv "$f.part" "$f"
  fi
done
shasum -a 256 -c SHA256SUMS
rm -rf love-11.5-ios-source love-apple-dependencies __MACOSX
unzip -q love-11.5-ios-source.zip -x '__MACOSX/*'
unzip -q love-11.5-apple-libraries.zip -x '__MACOSX/*'
rm -rf love-11.5-ios-source/platform/xcode/ios/libraries
cp -R love-apple-dependencies/iOS/libraries love-11.5-ios-source/platform/xcode/ios/libraries
echo "staged $src (LOVE 11.5 iOS source + apple libraries)"
