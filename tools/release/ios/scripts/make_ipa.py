#!/usr/bin/env python3
"""Package an unsigned IPA (Payload/BalatroOverhaul.app) from the Xcode
build, add the launcher .love and licence/source notices, run the content
audit. AltStore/SideStore re-sign it. The corresponding source is this
repository at the commit named in SOURCE.md.

usage: scripts/make_ipa.py [--app PATH] [--out DIR] [--mock]
  --mock  accept a non-Mach-O executable (pipeline tests only; never publish)
"""
import argparse
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common as C  # noqa: E402

MACHO = (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", default=str(C.WORK / "xcbuild/Release-iphoneos/love.app"))
    ap.add_argument("--out", default=str(C.OUT))
    ap.add_argument("--launcher", default=str(C.WORK / C.LAUNCHER_NAME))
    ap.add_argument("--mock", action="store_true")
    args = ap.parse_args()
    app, out, launcher = Path(args.app), Path(args.out), Path(args.launcher)
    if not (app / "Info.plist").is_file():
        C.die("no built app at %s (run scripts/build_app.sh first)" % app)
    if not launcher.is_file():
        C.die("no launcher at %s (run scripts/make_launcher_love.py)" % launcher)
    with open(app / "Info.plist", "rb") as f:
        info = plistlib.load(f)
    name, code, _ = C.overhaul_version()
    if info.get("CFBundleIdentifier") != C.BUNDLE_ID:
        C.die("bundle id is %r, want %s" % (info.get("CFBundleIdentifier"), C.BUNDLE_ID))
    if info.get("CFBundleShortVersionString") != name or str(info.get("CFBundleVersion")) != code:
        C.die("version is %r (%r), want %s (%s)" % (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"), name, code))
    exe = app / info.get("CFBundleExecutable", "love")
    if not exe.is_file():
        C.die("executable %s missing" % exe)
    if not args.mock and exe.read_bytes()[:4] not in MACHO:
        C.die("%s is not a Mach-O binary" % exe)

    stage = out / ".stage"
    if stage.exists():
        shutil.rmtree(stage)
    dst_app = stage / "Payload" / C.APP_DIR_NAME
    shutil.copytree(app, dst_app, symlinks=False)
    shutil.rmtree(dst_app / "_CodeSignature", ignore_errors=True)
    (dst_app / "embedded.mobileprovision").unlink(missing_ok=True)
    for stray in dst_app.glob("*.love"):
        stray.unlink()
    shutil.copy2(launcher, dst_app / C.LAUNCHER_NAME)
    for n in C.NOTICE_FILES:
        shutil.copy2(C.OVERHAUL / n, dst_app / n)
    for n, path in C.PORT_NOTICES.items():
        shutil.copy2(path, dst_app / n)
    shutil.copy2(C.LOVE_SRC / "license.txt", dst_app / "LICENSE-LOVE.txt")
    (dst_app / "SOURCE.md").write_text(C.source_notice(), encoding="utf-8")

    tag = "-MOCK" if args.mock else ""
    ipa = out / ("BalatroOverhaul-%s-unsigned%s.ipa" % (name, tag))
    C.write_zip(ipa, stage, C.tree_files(stage), dirs=True, compresslevel=None)
    shutil.rmtree(stage)
    print("ipa: %s (%d bytes)" % (ipa, ipa.stat().st_size))

    report = out / (ipa.stem + ".AUDIT.txt")
    rc = subprocess.run([sys.executable, str(C.IOS / "scripts/audit_ipa.py"), str(ipa), "--report", str(report)]).returncode
    if rc != 0:
        ipa.rename(ipa.with_suffix(".ipa.REJECTED"))
        C.die("audit failed, IPA renamed to .REJECTED; see %s" % report)
    sums = out / "SHA256SUMS"
    lines = ["%s  %s" % (C.sha256(p.read_bytes()), p.name) for p in sorted(out.iterdir())
             if p.is_file() and p.name != "SHA256SUMS" and (p.suffix in (".ipa", ".txt"))]
    sums.write_text("\n".join(lines) + "\n")
    print(sums.read_text(), end="")


if __name__ == "__main__":
    main()
