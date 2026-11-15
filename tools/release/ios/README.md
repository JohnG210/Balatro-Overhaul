# Balatro Overhaul for iOS / iPadOS

An unsigned IPA of the Overhaul launcher running on LOVE 11.5 for iOS, meant
for sideloading with AltStore or SideStore. It works the same way as the
Android "Make APK from Steam" path:

- The IPA contains **no Balatro files**: only LOVE 11.5, this launcher, the
  Overhaul patch set (`game/`), `tools/release/patcher` and the licences.
- On first launch the player taps **Import** and picks **their own** Steam
  copy in the Files app (`Balatro.exe`, `Balatro.love`, a zip of
  `Balatro.app`, or a zip of the game folder). The launcher checks every
  vanilla file against `game/manifest.lua`, builds the patched game in the
  app sandbox with `patcher/apply.lua`, deletes the picked copy and starts
  the game. Lovely/Steamodded patches run through the Overhaul's pure-Lua
  loader, as on Android. There is no native injection and no JIT.
- Getting the file onto the phone: AirDrop it, use iCloud Drive, or connect
  to a computer share in Files (Connect to Server).

## What the iOS layer adds

`native/overhaul_ios.mm` (compiled into LOVE through `src/common/ios.mm`,
preloaded as the Lua module `overhaul_ios`):

- Files picker (`UIDocumentPickerViewController`) and the app's Documents
  folder (visible in Files; dropping a `reimport.txt` there brings back the
  import screen on next launch).
- UIScene lifecycle bridge. Apps built with the iOS 27 SDK must use scenes,
  and SDL 2 in LOVE 11.5 does not, so without this the app shows a black
  screen. It is a no-op on older SDKs.
- Screen size handling for rotation and foldables (iPhone Duo fold/unfold):
  keeps SDL's view, GL drawable and LOVE's window size in step with UIKit.
- Haptics: plays the game's `G.HAPTIC_LEVEL` buzzes on the Taptic Engine,
  honouring the in-game Haptic Feedback toggle and intensity slider.

`lua/` (the launcher `.love`, next to the app binary):

- `ios_import.lua`: import screen, picker flow, version checks and messages.
- `ios_runtime.lua`: software keyboard while a text box has focus, capital
  letters from the iOS keyboard, haptics, and re-layout on size changes
  (including a late resize with the old orientation that SDL sometimes
  sends after a rotation).
- `main.lua` / `conf.lua`: start the installed game, or the import screen.

## Build with GitHub Actions (no Mac needed)

After this workflow is merged into the repository's default branch:

1. Open **Actions → Build iOS IPA → Run workflow**.
2. Select the branch or release tag to build, then press **Run workflow**.
   That ref must contain the iOS workflow and port. Version/build numbers
   are read from that ref's `game/manifest.lua`; update the manifest before
   building a new release.
3. Open the completed run and download **BalatroOverhaul-iOS-<run number>**
   under **Artifacts** (GitHub login required). Unzip it to get the unsigned
   IPA, `SHA256SUMS`, and the content-audit report.
4. If publishing a release, upload those files to the GitHub release yourself.
   Rebuilding does not automatically publish or replace any release assets.

The workflow also builds on relevant pull requests and pushes. It needs
no Apple account, signing certificates or repository secrets. The token
has read-only repository permissions; AltStore/SideStore signs the IPA on
installation. Artifacts expire after 30 days, so attach the IPA and notices
to a release for permanent distribution.

The standard `xcode-27` runner uses Xcode 27.2 and the iOS 27.2 SDK,
matching the toolchain used for the local Duo build. This runner is free
for public repositories, but is currently a preview image: queue times
and availability may vary. No paid larger runner is used. A green build
proves compilation and the content audit, not on-device gameplay, Duo
fold/rotation behavior or haptics.

## Build locally

Needs macOS with full Xcode (tested with Xcode 26.5 and 27.2; 27.x is
needed for iPhone Duo / iOS 27 devices). Run from the repository root:

```sh
tools/release/ios/scripts/fetch_sources.sh       # LOVE 11.5 iOS source + apple libraries, sha256-checked
python3 -B tools/release/ios/scripts/prepare_love.py
tools/release/ios/scripts/build_app.sh           # unsigned Release build, arm64
python3 -B tools/release/ios/scripts/make_launcher_love.py
python3 -B tools/release/ios/scripts/make_ipa.py # -> tools/release/ios/build/out/BalatroOverhaul-<ver>-unsigned.ipa
```

Everything is written under `tools/release/ios/build/` (git-ignored).
Version and build number come from `game/manifest.lua`. The bundle id
defaults to `io.github.jupiteriansoul.balatrooverhaul`; set
`OVERHAUL_IOS_BUNDLE_ID` to change it. When building from a fork, set
`OVERHAUL_IOS_SOURCE_URL` to the fork's URL so `SOURCE.md` points at a
repository that actually has the commit. AltStore/SideStore re-sign the IPA
with the user's own Apple ID, so no signing identity is needed.

`make_ipa.py` runs `audit_ipa.py` and refuses to produce an IPA that
contains anything that looks like a Balatro file, lacks the licence and
source notices, or lacks zip directory entries (AltStore needs them).
The build scripts refuse to run with uncommitted changes, because the
IPA's `SOURCE.md` names the current commit as the corresponding source
(`OVERHAUL_IOS_ALLOW_DIRTY=1` for local test builds).

If the first build fails in ibtool with "iOS <version> Platform Not
Installed", run `xcodebuild -downloadPlatform iOS`.

### Simulator build

```sh
xcodebuild -project tools/release/ios/build/work/love/platform/xcode/love.xcodeproj \
  -target love-ios -configuration Debug -sdk iphonesimulator ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  SYMROOT=$PWD/tools/release/ios/build/sim OBJROOT=$PWD/tools/release/ios/build/sim build
cp tools/release/ios/build/work/overhaul-launcher.love \
   tools/release/ios/build/sim/Debug-iphonesimulator/love.app/
xcrun simctl install booted tools/release/ios/build/sim/Debug-iphonesimulator/love.app
```

Note the Simulator renders OpenGL in software, so the game runs at a few
frames per second there; it is fine on a device.

## Tests

`tests/run_tests.sh [path/to/love]` needs no Xcode and no Balatro copy. It
runs the importer's error paths in desktop LOVE 11.5 with synthetic
fixtures, packages a mock IPA (must pass the audit), and checks that the
audit rejects poisoned IPAs (Balatro-like files, an injected
`Balatro.love`, missing zip directory entries).

## Installing (players)

1. Install AltStore or SideStore on the device.
2. Open the IPA with it. A free Apple ID allows 3 sideloaded apps and needs
   a refresh every 7 days (AltStore/SideStore do it in the background).
3. Open **Balatro Overhaul**, tap **Import my Balatro file**, pick your Steam copy, wait for
   the patch (about a minute), then play.

Tested on an iPhone and the iPhone Duo simulator (iOS 27.2: folded,
unfolded, and rotation through all four orientations in both).

## Licences

The port's own code is GPL-3.0-or-later like the rest of the Overhaul.
`notices/THIRD_PARTY_IOS.md` covers the statically linked iOS libraries
(SDL2, libogg, libvorbis, libtheora, libmodplug, LuaJIT). LOVE's iOS build
leaves out libmpg123 (LGPL-2.1, `LOVE_NOMPG123`), so there is no MP3
decoding; `build_app.sh` fails if it ever gets linked.
