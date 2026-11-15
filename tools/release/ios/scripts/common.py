"""Shared paths and checks for the Balatro Overhaul iOS build scripts.

Inputs: this repository (the Overhaul patch set, bootstrap and patcher),
tools/release/ios (the iOS port's own code) and the official LOVE 11.5
iOS release zips, staged into tools/release/ios/build/src and pinned by
tools/release/ios/SHA256SUMS. Nothing from Balatro is ever read.
"""
import hashlib
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path

IOS = Path(__file__).resolve().parent.parent          # tools/release/ios
OVERHAUL = IOS.parent.parent.parent                    # repository root
BUILD = IOS / "build"                                  # git-ignored
SRC = BUILD / "src"
SUMS = IOS / "SHA256SUMS"
LOVE_SRC = SRC / "love-11.5-ios-source"
OVERHAUL_URL = "https://github.com/JupiterianSoul/Balatro-Overhaul"
LOVE_URL = "https://github.com/love2d/love/releases/tag/11.5"
WORK = BUILD / "work"
OUT = BUILD / "out"
# AltStore/SideStore re-sign with the user's own team, so any id works.
BUNDLE_ID = os.environ.get("OVERHAUL_IOS_BUNDLE_ID", "io.github.jupiteriansoul.balatrooverhaul")
DISPLAY_NAME = "Balatro Overhaul"
LAUNCHER_NAME = "overhaul-launcher.love"
APP_DIR_NAME = "BalatroOverhaul.app"
ZIP_DATE = (2026, 1, 1, 0, 0, 0)
PATCHER_LUA = ["apply.lua", "zipread.lua", "love_ctx.lua"]
NOTICE_FILES = ["LICENSE", "COPYRIGHT.md", "THIRD_PARTY_NOTICES.md"]
PORT_NOTICES = {"THIRD_PARTY_IOS.md": IOS / "notices" / "THIRD_PARTY_IOS.md"}
DEPS_URL = "https://github.com/love2d/love/releases/download/11.5/love-11.5-apple-libraries.zip"
DEPS_REPO = "https://github.com/love2d/love-apple-dependencies (tag 11.5)"
LOVE_SRC_URL = "https://github.com/love2d/love/releases/download/11.5/love-11.5-ios-source.zip"


def die(msg):
    print("error: " + msg, file=sys.stderr)
    sys.exit(1)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def manifest_text():
    return (OVERHAUL / "game" / "manifest.lua").read_text(encoding="utf-8")


def overhaul_version():
    text = manifest_text()
    name = re.search(r'^  overhaul_name = "(.*)",$', text, re.M)
    code = re.search(r'^  overhaul_version = "(.*)",$', text, re.M)
    game = re.search(r'^  game_version = "(.*)",$', text, re.M)
    if not (name and code and game):
        die("cannot read version from game/manifest.lua")
    return name.group(1), code.group(1), game.group(1)


def overhaul_rev():
    return subprocess.run(["git", "-C", str(OVERHAUL), "rev-parse", "HEAD"],
                          capture_output=True, text=True, check=True).stdout.strip()


def check_sources():
    if not LOVE_SRC.is_dir():
        die("LOVE sources not staged; run tools/release/ios/scripts/fetch_sources.sh")
    for line in SUMS.read_text().splitlines():
        if not line.strip():
            continue
        want, name = line.split()
        got = sha256((SRC / name).read_bytes())
        if got != want:
            die("%s sha256 %s, SHA256SUMS says %s" % (name, got, want))
    # SOURCE.md names the commit as the corresponding source, so the inputs
    # must match it (set OVERHAUL_IOS_ALLOW_DIRTY=1 for local test builds).
    dirty = subprocess.run(["git", "-C", str(OVERHAUL), "status", "--porcelain", "--",
                            "game", "tools/release", "LICENSE", "COPYRIGHT.md", "THIRD_PARTY_NOTICES.md"],
                           capture_output=True, text=True, check=True).stdout.strip()
    if dirty and os.environ.get("OVERHAUL_IOS_ALLOW_DIRTY") != "1":
        die("working tree has uncommitted changes (SOURCE.md would not match the commit):\n" + dirty)


def overhaul_files(prefix):
    out = subprocess.run(["git", "-C", str(OVERHAUL), "ls-files", "-z", "--", prefix],
                         capture_output=True, check=True).stdout.decode().split("\0")
    return sorted(p for p in out if p)


def transform_install(text):
    """overhaul_install.lua reads the game from an Android-only env var.
    Add one hook so the iOS importer supplies the user's picked file."""
    old = "local function open_vanilla(report)\n"
    if text.count(old) != 1:
        die("overhaul_install.lua: open_vanilla anchor not found exactly once")
    new = old + "\tif M.ios_open then return M.ios_open(report, copy_official) end\n"
    return text.replace(old, new)


def source_notice():
    name, code, game = overhaul_version()
    sums = {}
    for line in SUMS.read_text().splitlines():
        if line.strip():
            h, n = line.split()
            sums[n] = h
    return f"""Balatro Overhaul for iOS {name} (build {code})
================================================

This app is LOVE 11.5 (zlib licence) running the Balatro Overhaul launcher
(GNU GPL-3.0-or-later). It does NOT contain Balatro: no game code, art,
sound, music or fonts. On first launch you import your OWN copy of Balatro
(Steam {game}); the Overhaul patch set is applied to it on this device.

Corresponding source (GPL-3.0 section 6):
- Balatro Overhaul {name}, including this iOS port (tools/release/ios):
  {OVERHAUL_URL} at commit {overhaul_rev()}
- LOVE 11.5 iOS source: {LOVE_SRC_URL}
  sha256 {sums.get("love-11.5-ios-source.zip", "?")}
- LOVE 11.5 prebuilt iOS libraries (SDL2, ogg, vorbis, theora, modplug,
  FreeType, LuaJIT): {DEPS_URL}
  sha256 {sums.get("love-11.5-apple-libraries.zip", "?")}
  source tree: {DEPS_REPO}
- Rebuild: tools/release/ios/README.md (fetch_sources.sh stages and
  sha256-checks the LOVE zips above, then prepare_love.py, build_app.sh,
  make_launcher_love.py and make_ipa.py rebuild this IPA).

libmpg123 (LGPL-2.1) is not included: the iOS build uses LOVE_NOMPG123,
so there is no MP3 decoding. See THIRD_PARTY_IOS.md.

Licences: LICENSE (GPL-3.0), COPYRIGHT.md, THIRD_PARTY_NOTICES.md
(Overhaul components), THIRD_PARTY_IOS.md (statically linked iOS
libraries: SDL2, libogg, libvorbis, libtheora, libmodplug, LuaJIT),
LICENSE-LOVE.txt (LOVE and its bundled libraries).
"""


def zip_dirs(names):
    """Every parent directory of names, in first-appearance order
    (same order as scripts/add_zip_dirs.py), each ending in '/'."""
    dirs = []
    for name in names:
        parts = name.split("/")[:-1]
        for n in range(1, len(parts) + 1):
            d = "/".join(parts[:n]) + "/"
            if d not in dirs:
                dirs.append(d)
    return dirs


def write_zip(dst, root, names, dirs=False, compresslevel=9):
    """Deterministic zip: sorted names, fixed timestamps.
    dirs=True first writes explicit directory entries (stored, mode 40755,
    DOS dir bit). AltStore's unzip needs them ('file doesn't exist' without).
    The IPA uses dirs=True, compresslevel=None (zlib default), the same as
    add_zip_dirs.py, which produced the published IPA."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_suffix(dst.suffix + ".tmp")
    names = sorted(names)
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=compresslevel) as z:
        if dirs:
            for d in zip_dirs(names):
                info = zipfile.ZipInfo(d, ZIP_DATE)
                info.create_system = 3
                info.external_attr = (0o40755 << 16) | 0x10
                info.compress_type = zipfile.ZIP_STORED
                z.writestr(info, b"")
        for name in names:
            path = root / name
            info = zipfile.ZipInfo(name, ZIP_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            mode = 0o755 if os.access(path, os.X_OK) else 0o644
            info.external_attr = (0o100000 | mode) << 16
            info.create_system = 3
            z.writestr(info, path.read_bytes())
    os.replace(tmp, dst)


def tree_files(root):
    return sorted(p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file() and not p.is_symlink())
