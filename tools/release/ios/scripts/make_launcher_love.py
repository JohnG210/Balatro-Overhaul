#!/usr/bin/env python3
"""Build work/overhaul-launcher.love: iOS importer + Overhaul bootstrap,
patcher and GPL patch set. No Balatro file is read or included.

usage: scripts/make_launcher_love.py [--out FILE]
"""
import argparse
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common as C  # noqa: E402


def stage(dst):
    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True)
    for name in ("main.lua", "conf.lua", "ios_import.lua", "ios_runtime.lua"):
        shutil.copy2(C.IOS / "lua" / name, dst / name)
    boot = C.OVERHAUL / "tools/release/android/bootstrap/overhaul_install.lua"
    (dst / "overhaul_install.lua").write_text(C.transform_install(boot.read_text(encoding="utf-8")), encoding="utf-8")
    (dst / "patcher").mkdir()
    for name in C.PATCHER_LUA:
        shutil.copy2(C.OVERHAUL / "tools/release/patcher" / name, dst / "patcher" / name)
    for rel in C.overhaul_files("game"):
        out = dst / "patch" / rel[len("game/"):]
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(C.OVERHAUL / rel, out)
    for name in C.NOTICE_FILES:
        shutil.copy2(C.OVERHAUL / name, dst / name)
    for name, path in C.PORT_NOTICES.items():
        shutil.copy2(path, dst / name)
    shutil.copy2(C.LOVE_SRC / "license.txt", dst / "LICENSE-LOVE.txt")
    (dst / "SOURCE.md").write_text(C.source_notice(), encoding="utf-8")
    return dst


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(C.WORK / C.LAUNCHER_NAME))
    args = ap.parse_args()
    C.check_sources()
    root = stage(C.WORK / "launcher")
    names = C.tree_files(root)
    out = Path(args.out)
    C.write_zip(out, root, names)
    print("launcher: %s (%d files, %d bytes, sha256 %s)" % (out, len(names), out.stat().st_size, C.sha256(out.read_bytes())))


if __name__ == "__main__":
    main()
