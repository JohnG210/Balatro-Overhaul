#!/usr/bin/env bash
# Tests that need no Xcode and no Balatro copy:
#  1. importer error paths in real LOVE 11.5 (desktop) with synthetic fixtures
#  2. IPA packaging + audit on a MOCK app (must PASS)
#  3. audit on a poisoned mock (must FAIL)
# usage: tools/release/ios/tests/run_tests.sh [path/to/love]
#   (default: build/tools-cache/love.app, the LOVE 11.5 macOS app)
set -euo pipefail
ios="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$ios/build/work"
love="${1:-$ios/build/tools-cache/love.app/Contents/MacOS/love}"
t="$work/tests"
rm -rf "$t"; mkdir -p "$t/fixtures"
python3 -B "$ios/scripts/make_launcher_love.py" >/dev/null

echo "=== 1 importer (LOVE: $("$love" --version)) ==="
python3 - "$t/fixtures" <<'EOF'
import io, os, sys, zipfile
d = sys.argv[1]
def z(entries):
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w") as f:
        for k, v in entries.items(): f.writestr(k, v)
    return b.getvalue()
game = {"main.lua": "-- synthetic stand-in, not Balatro\n", "version.jkr": "0.9.0-FAKE\n"}
open(f"{d}/random.bin", "wb").write(os.urandom(4096))
open(f"{d}/fake.exe", "wb").write(b"MZ" + os.urandom(4096))
open(f"{d}/nogame.zip", "wb").write(z({"readme.txt": "hello"}))
open(f"{d}/folder.zip", "wb").write(z({"Balatro/" + k: v for k, v in game.items()}))
open(f"{d}/Balatro.exe", "wb").write(b"MZ" + b"\0" * 8192 + z(game))
open(f"{d}/app.zip", "wb").write(z({"Balatro.app/Contents/Resources/Balatro.love": z(game)}))
EOF
app="$t/importer"; cp -R "$work/launcher" "$app"
mv "$app/main.lua" "$app/main_real.lua"
cp "$ios/tests/importer/main.lua" "$app/main.lua"
printf 'function love.conf(t) t.identity = "BalatroOverhaulTest" t.window = false end\n' > "$app/conf.lua"
FIXTURES="$t/fixtures" "$love" "$app"

echo "=== 2 mock IPA (must PASS) ==="
mock="$t/mock/love.app"; mkdir -p "$mock"
cp "$work/love/platform/xcode/ios/love-ios.plist" "$mock/Info.plist"
plutil -replace CFBundleExecutable -string love "$mock/Info.plist"
printf '#!/bin/sh\n# mock executable\n' > "$mock/love"; chmod +x "$mock/love"
python3 -B "$ios/scripts/make_ipa.py" --mock --app "$mock" --out "$t/out"

echo "=== 3 poisoned mock (must FAIL) ==="
printf 'Card = Moveable:extend()\n-- LocalThunk\n' > "$mock/card.lua"
printf 'x' > "$mock/Balatro.love"; mkdir -p "$mock/resources/textures/1x"; printf 'png' > "$mock/resources/textures/1x/Jokers.png"
if python3 -B "$ios/scripts/make_ipa.py" --mock --app "$mock" --out "$t/poison" 2>&1 | tee "$t/poison.log"; then
  echo "FAIL: poisoned IPA passed the audit"; exit 1
fi
grep -c '^FAIL ' "$t/poison/"*.AUDIT.txt

echo "=== 4 Balatro.love injected straight into the IPA (must FAIL) ==="
mockipa=$(ls "$t"/out/BalatroOverhaul-*-unsigned-MOCK.ipa)
cp "$mockipa" "$t/inject.ipa"
python3 -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1],"a").writestr("Payload/BalatroOverhaul.app/Balatro.love","x")' "$t/inject.ipa"
if python3 -B "$ios/scripts/audit_ipa.py" "$t/inject.ipa" --report "$t/inject.AUDIT.txt"; then
  echo "FAIL: injected Balatro.love passed"; exit 1
fi

echo "=== 5 IPA without directory entries (the AltStore 'file doesn't exist' bug, must FAIL) ==="
python3 - "$mockipa" "$t/nodirs.ipa" <<'EOF'
import sys, zipfile
zin = zipfile.ZipFile(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], "w", zipfile.ZIP_DEFLATED) as zout:
    for i in zin.infolist():
        if not i.is_dir():
            zout.writestr(i, zin.read(i))
EOF
if python3 -B "$ios/scripts/audit_ipa.py" "$t/nodirs.ipa" --report "$t/nodirs.AUDIT.txt"; then
  echo "FAIL: IPA without directory entries passed"; exit 1
fi
echo "ALL TESTS PASS"
