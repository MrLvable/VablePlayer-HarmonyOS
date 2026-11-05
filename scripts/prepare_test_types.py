"""Extract only the pinned MPV declaration needed by offline tests, without an SDK."""
from pathlib import Path
import hashlib
import tarfile
import zipfile

ROOT=Path(__file__).resolve().parents[1]
archive=ROOT/'vendor/mpv-arkts-1.0.0.har'
if hashlib.sha256(archive.read_bytes()).hexdigest()!='facaf095b77045d91cc0787f0544b4681b1c5fe6c7c635823c56f9eb16d6dbff':
    raise SystemExit('Run bootstrap_deps.py; the MPV archive must match the pinned hash.')
if zipfile.is_zipfile(archive):
    with zipfile.ZipFile(archive) as package:
        names=[n for n in package.namelist() if n.endswith('/MpvLib.d.ets')]
        if len(names)!=1: raise ValueError('Unexpected declaration layout')
        data=package.read(names[0])
else:
    with tarfile.open(archive,'r:*') as package:
        names=[n for n in package if n.isfile() and n.name.endswith('/MpvLib.d.ets')]
        if len(names)!=1 or names[0].size>4*1024*1024:raise ValueError('Unexpected declaration layout')
        data=package.extractfile(names[0]).read()
target=ROOT/'.cache/mpv/MpvLib.d.ets'
target.parent.mkdir(parents=True,exist_ok=True)
target.write_bytes(data)
print('Prepared .cache/mpv/MpvLib.d.ets (test declaration only, not an installed app dependency)')
