#!/usr/bin/env python3
"""Content audit for the Balatro Overhaul iOS IPA. Lists every entry (and
every entry of the nested launcher .love) and FAILS on anything that is,
or may be, Balatro content.

Checks
1. Hash: any entry whose sha256 equals a Balatro file or a Balatro-derived
   output listed in the Overhaul manifest (vanilla, keep, patch and image
   entries) fails. This is the exact check for base-game files.
2. Names: Balatro.love, Balatro.exe, game.love, version.jkr, official.zip,
   picked_game.bin; any launcher path (outside patch/) or app path equal to
   a vanilla Balatro path (game.lua, card.lua, resources/...); any
   resources/textures|sounds|fonts path outside the patch set.
3. Provenance: every launcher entry must be byte-identical to its source
   (Overhaul repo at the pinned commit, this port's ios/lua, or the generated
   notices). Unknown files fail.
4. Content: "LocalThunk" (any case) fails except in the Overhaul's own
   licence/disclaimer files (byte-identical to the repo). Base-game class
   definitions (e.g. "Card = Moveable:extend()") fail.
5. Exactly one .love in the app: overhaul-launcher.love.

usage: scripts/audit_ipa.py IPA [--report FILE]
"""
import argparse
import io
import re
import sys
import zipfile
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common as C  # noqa: E402

BANNED_NAMES = {"balatro.love", "balatro.exe", "game.love", "version.jkr", "official.zip", "picked_game.bin"}
ASSET_DIR = re.compile(r"(^|/)resources/(textures|sounds|fonts)/", re.I)
THUNK = re.compile(rb"localthunk", re.I)
CLASS_MARKERS = [re.compile(p, re.M) for p in (
    rb"^Card = Moveable:extend\(\)",
    rb"^Game = Object:extend\(\)",
    rb"^CardArea = Moveable:extend\(\)",
    rb"^Blind = Moveable:extend\(\)",
    rb"^Tag = Object:extend\(\)",
    rb"^Back = Object:extend\(\)",
)]
THUNK_OK = {  # Overhaul's own licence / credit / disclaimer files
    "COPYRIGHT.md", "THIRD_PARTY_NOTICES.md", "README.md", "manifest.lua", "files/GPL-3.0.txt",
    "files/THIRD_PARTY_NOTICES.md", "files/resources/workshop/index.lua",
    "patches/functions/release_info.lua.bop",
}


def manifest_tables():
    """Return (forbidden sha256 set, vanilla paths) from game/manifest.lua."""
    forbidden, vanilla_paths = set(), set()
    block, in_vanilla = None, False
    for line in C.manifest_text().splitlines():
        if line == "  vanilla = {":
            in_vanilla = True
        if line == "    {":
            block = {}
        elif line in ("    },", "    }") and block is not None:
            if in_vanilla:
                vanilla_paths.add(block.get("path", ""))
            if in_vanilla or block.get("kind") != "own":
                if block.get("sha256"):
                    forbidden.add(block["sha256"])
            block = None
        elif block is not None:
            m = re.match(r'^      (\w+) = "(.*)",$', line)
            if m:
                block[m.group(1)] = m.group(2)
    return forbidden, vanilla_paths


def expected_launcher():
    """Map launcher path -> sha256 of what make_launcher_love.py puts there."""
    exp = {}
    for name in ("main.lua", "conf.lua", "ios_import.lua", "ios_runtime.lua"):
        exp[name] = C.sha256((C.IOS / "lua" / name).read_bytes())
    boot = (C.OVERHAUL / "tools/release/android/bootstrap/overhaul_install.lua").read_text(encoding="utf-8")
    exp["overhaul_install.lua"] = C.sha256(C.transform_install(boot).encode("utf-8"))
    for name in C.PATCHER_LUA:
        exp["patcher/" + name] = C.sha256((C.OVERHAUL / "tools/release/patcher" / name).read_bytes())
    for rel in C.overhaul_files("game"):
        exp["patch/" + rel[len("game/"):]] = C.sha256((C.OVERHAUL / rel).read_bytes())
    for name in C.NOTICE_FILES:
        exp[name] = C.sha256((C.OVERHAUL / name).read_bytes())
    for name, path in C.PORT_NOTICES.items():
        exp[name] = C.sha256(path.read_bytes())
    exp["LICENSE-LOVE.txt"] = C.sha256((C.LOVE_SRC / "license.txt").read_bytes())
    exp["SOURCE.md"] = C.sha256(C.source_notice().encode("utf-8"))
    return exp


class Audit:
    def __init__(self):
        self.forbidden, self.vanilla = manifest_tables()
        self.expected = expected_launcher()
        self.lines, self.fails = [], []

    def fail(self, where, why):
        self.fails.append("%s: %s" % (where, why))

    def content(self, where, data, verified, thunk_rel=None):
        if C.sha256(data) in self.forbidden:
            self.fail(where, "sha256 matches a Balatro (or Balatro-derived) file from the manifest")
        if THUNK.search(data) and not (verified and thunk_rel in THUNK_OK):
            self.fail(where, "contains 'LocalThunk' outside the Overhaul's own notices")
        if not verified:
            for m in CLASS_MARKERS:
                if m.search(data):
                    self.fail(where, "contains base-game code marker %r" % m.pattern.decode())

    def names(self, where, rel, in_patch, port_own=False):
        base = PurePosixPath(rel).name.lower()
        if base in BANNED_NAMES:
            self.fail(where, "banned file name %s" % base)
        if not in_patch:
            # main.lua / conf.lua of the launcher share names with Balatro's
            # files; allowed only when byte-identical to this port's ios/lua.
            if rel in self.vanilla and not port_own:
                self.fail(where, "path is a Balatro file path")
            if ASSET_DIR.search(rel):
                self.fail(where, "Balatro asset folder outside the Overhaul patch set")
        else:
            inner = rel[len("patch/"):]
            if inner.startswith("files/") and inner[len("files/"):] in self.vanilla:
                self.fail(where, "patch set ships a full Balatro file path")

    def launcher(self, ipa_name, data):
        z = zipfile.ZipFile(io.BytesIO(data))
        seen = set()
        for info in z.infolist():
            if info.is_dir():
                continue
            rel = info.filename
            where = "%s!%s" % (ipa_name, rel)
            body = z.read(info)
            sha = C.sha256(body)
            self.lines.append("  %10d %s %s" % (info.file_size, sha[:16], where))
            want = self.expected.get(rel)
            verified = want == sha
            if want is None:
                self.fail(where, "unknown file (not from the Overhaul repo or this port)")
            elif not verified:
                self.fail(where, "differs from its source")
            seen.add(rel)
            in_patch = rel.startswith("patch/")
            port_own = verified and rel in ("main.lua", "conf.lua")
            self.names(where, rel, in_patch, port_own)
            thunk_rel = rel[len("patch/"):] if in_patch else rel
            self.content(where, body, verified, thunk_rel)
        missing = sorted(set(self.expected) - seen)
        if missing:
            self.fail(ipa_name, "launcher is missing %d expected files, e.g. %s" % (len(missing), missing[:3]))
        return len(seen)

    def ipa(self, path):
        z = zipfile.ZipFile(path)
        loves, apps = [], set()
        # AltStore refuses IPAs whose parent directories have no entry of
        # their own ("file doesn't exist"): every parent must be listed.
        dir_entries = {i.filename for i in z.infolist() if i.is_dir()}
        for i in z.infolist():
            if i.is_dir():
                self.lines.append("%10s %s %s" % ("dir", "-" * 16, i.filename))
            for d in C.zip_dirs([i.filename.rstrip("/")]):
                if d not in dir_entries:
                    self.fail(i.filename, "parent directory entry %s is missing" % d)
        if "Payload/" not in dir_entries:
            self.fail(str(path), "no Payload/ directory entry")
        for info in z.infolist():
            if info.is_dir():
                continue
            name = info.filename
            body = z.read(info)
            self.lines.append("%10d %s %s" % (info.file_size, C.sha256(body)[:16], name))
            parts = name.split("/")
            if parts[0] != "Payload" or len(parts) < 3 or not parts[1].endswith(".app"):
                self.fail(name, "entry outside Payload/*.app")
                continue
            apps.add(parts[1])
            rel = "/".join(parts[2:])
            if rel.lower().endswith(".love"):
                loves.append(rel)
                if rel == C.LAUNCHER_NAME:
                    self.content(name, body, True, "")
                    n = self.launcher(name, body)
                    self.lines.append("  (%d launcher entries)" % n)
                    continue
            self.names(name, rel, False)
            notice = (rel in C.NOTICE_FILES or rel in C.PORT_NOTICES) and C.sha256(body) == self.expected.get(rel)
            self.content(name, body, notice, rel if notice else None)
        if loves != [C.LAUNCHER_NAME]:
            self.fail(str(path), "expected exactly one .love (%s), found %s" % (C.LAUNCHER_NAME, loves))
        if len(apps) != 1:
            self.fail(str(path), "expected one .app, found %s" % sorted(apps))
        for need in ("LICENSE", "SOURCE.md", "THIRD_PARTY_NOTICES.md", "THIRD_PARTY_IOS.md", "LICENSE-LOVE.txt", "Info.plist"):
            if not any(e == "Payload/%s/%s" % (a, need) for a in apps for e in z.namelist()):
                self.fail(str(path), "missing %s" % need)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ipa")
    ap.add_argument("--report")
    args = ap.parse_args()
    a = Audit()
    a.ipa(args.ipa)
    head = ["Balatro Overhaul iOS IPA content audit", "ipa: %s" % args.ipa,
            "sha256: %s" % C.sha256(Path(args.ipa).read_bytes()),
            "forbidden hashes from manifest: %d, vanilla paths: %d" % (len(a.forbidden), len(a.vanilla)),
            "entries:"]
    tail = ["", "RESULT: %s (%d failures)" % ("FAIL" if a.fails else "PASS", len(a.fails))] + ["FAIL " + f for f in a.fails]
    text = "\n".join(head + a.lines + tail) + "\n"
    if args.report:
        Path(args.report).write_text(text)
    print("\n".join(head[:4] + ["(%d entries listed%s)" % (len(a.lines), " in " + args.report if args.report else "")] + tail[:12]))
    if not args.report:
        print(text)
    sys.exit(1 if a.fails else 0)


if __name__ == "__main__":
    main()
