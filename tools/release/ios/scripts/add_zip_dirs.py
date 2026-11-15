#!/usr/bin/env python3
"""Re-pack BalatroOverhaul IPA with explicit directory entries (Payload/, Payload/X.app/).
AltStore's unzip fails with "file doesn't exist" when an IPA has file entries only. Contents byte-identical."""
import hashlib, sys, zipfile

src, dst = sys.argv[1], sys.argv[2]
zin = zipfile.ZipFile(src)
infos = zin.infolist()
dirs = []
for i in infos:
    parts = i.filename.split('/')[:-1]
    for n in range(1, len(parts) + 1):
        d = '/'.join(parts[:n]) + '/'
        if d not in dirs:
            dirs.append(d)
with zipfile.ZipFile(dst, 'w') as zout:
    for d in dirs:
        zi = zipfile.ZipInfo(d, date_time=(2026, 1, 1, 0, 0, 0))
        zi.create_system = 3
        zi.external_attr = (0o40755 << 16) | 0x10
        zout.writestr(zi, b'')
    for i in infos:
        zi = zipfile.ZipInfo(i.filename, date_time=i.date_time)
        zi.create_system = 3
        zi.external_attr = i.external_attr
        zi.compress_type = i.compress_type
        zout.writestr(zi, zin.read(i.filename))
a = {i.filename: hashlib.sha256(zin.read(i)).hexdigest() for i in infos}
zb = zipfile.ZipFile(dst)
b = {i.filename: hashlib.sha256(zb.read(i)).hexdigest() for i in zb.infolist() if not i.is_dir()}
assert a == b, 'content mismatch'
assert zb.testzip() is None
print('dirs added', dirs, 'files identical', len(a))
