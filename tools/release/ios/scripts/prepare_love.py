#!/usr/bin/env python3
"""Copy the staged LOVE 11.5 iOS source to build/work/love and apply the port's
changes: native bridge (Files picker, UIScene lifecycle, resize, haptics),
Lua preload, deployment target 15.0, Info.plist (bundle id, display name,
version, file sharing / open-in-place, scenes, all orientations).

usage: scripts/prepare_love.py
"""
import json
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common as C  # noqa: E402

DEPLOY = "15.0"


SCENE_MANIFEST = {
    "UIApplicationSupportsMultipleScenes": False,
    "UISceneConfigurations": {
        "UIWindowSceneSessionRoleApplication": [{
            "UISceneConfigurationName": "Default",
            "UISceneDelegateClassName": "OverhaulSceneDelegate",
        }],
    },
}


def edit(path, old, new, count=1):
    text = path.read_text(encoding="utf-8")
    if text.count(old) != count:
        C.die("%s: anchor found %d times, want %d: %r" % (path, text.count(old), count, old))
    path.write_text(text.replace(old, new), encoding="utf-8")


def make_icons(dst):
    """Replace LOVE's icon set with the Overhaul's launcher icon (the same
    art as the Android launcher), one PNG per size in Contents.json."""
    src = C.OVERHAUL / "tools/release/android/icon/installer.png"
    icons = dst / "platform/xcode/Images.xcassets/iOS AppIcon.appiconset"
    for entry in json.loads((icons / "Contents.json").read_text())["images"]:
        if "filename" not in entry:
            continue
        pt = float(entry["size"].split("x")[0])
        px = str(round(pt * int(entry["scale"].rstrip("x"))))
        subprocess.run(["sips", "-s", "format", "png", "-z", px, px, str(src),
                        "--out", str(icons / entry["filename"])], check=True, capture_output=True)


def main():
    C.check_sources()
    dst = C.WORK / "love"
    if dst.exists():
        shutil.rmtree(dst)
    C.WORK.mkdir(parents=True, exist_ok=True)
    shutil.copytree(C.LOVE_SRC, dst, symlinks=True)

    common = dst / "src/common"
    shutil.copy2(C.IOS / "native/overhaul_ios.mm", common / "overhaul_ios.mm")
    with open(common / "ios.mm", "a", encoding="utf-8") as f:
        f.write('\n// Balatro Overhaul iOS port: Files picker bridge (GPL-3.0).\n#include "overhaul_ios.mm"\n')

    love_cpp = dst / "src/love.cpp"
    edit(love_cpp, '#include "common/ios.h"\n',
         '#include "common/ios.h"\nextern "C" int luaopen_overhaul_ios(lua_State *L);\n')
    edit(love_cpp, '\tlove_preload(L, luaopen_love, "love");\n',
         '\tlove_preload(L, luaopen_love, "love");\n#ifdef LOVE_IOS\n'
         '\tlove_preload(L, luaopen_overhaul_ios, "overhaul_ios");\n#endif\n')

    for proj in ("love.xcodeproj", "liblove.xcodeproj"):
        pbx = dst / "platform/xcode" / proj / "project.pbxproj"
        text = pbx.read_text(encoding="utf-8")
        text, n = re.subn(r"IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;", "IPHONEOS_DEPLOYMENT_TARGET = %s;" % DEPLOY, text)
        pbx.write_text(text, encoding="utf-8")
        print("%s: %d deployment targets -> %s" % (proj, n, DEPLOY))

    make_icons(dst)

    name, code, _ = C.overhaul_version()
    plist_path = dst / "platform/xcode/ios/love-ios.plist"
    with open(plist_path, "rb") as f:
        pl = plistlib.load(f)
    pl.update({
        "CFBundleIdentifier": C.BUNDLE_ID,
        "CFBundleDisplayName": C.DISPLAY_NAME,
        "CFBundleName": C.DISPLAY_NAME,
        "CFBundleShortVersionString": name,
        "CFBundleVersion": code,
        "UIFileSharingEnabled": True,
        "LSSupportsOpeningDocumentsInPlace": True,
        # iOS 27 SDK requires the UIScene lifecycle (see overhaul_ios.mm).
        "UIApplicationSceneManifest": SCENE_MANIFEST,
        # Follow the device in every orientation (iPhone Duo inner screen).
        "UISupportedInterfaceOrientations": [
            "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight",
        ],
    })
    with open(plist_path, "wb") as f:
        plistlib.dump(pl, f)
    print("prepared %s (bundle %s, version %s (%s))" % (dst, C.BUNDLE_ID, name, code))


if __name__ == "__main__":
    main()
