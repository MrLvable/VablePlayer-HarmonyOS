"""Restore pinned public upstream dependencies; never handles user credentials/signing."""
from pathlib import Path
import argparse
import hashlib
import io
import shutil
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MPV_URL = 'https://ohpm.openharmony.cn/ohpm/@mpv-ohos/mpv-arkts/-/mpv-arkts-1.0.0.har'
MPV_SHA = 'facaf095b77045d91cc0787f0544b4681b1c5fe6c7c635823c56f9eb16d6dbff'
SMB_URL = 'https://github.com/isaced/libsmb2-ohos/releases/download/v0.2.0/libsmb2-ohos.har'
SMB_HAR_SHA = 'cf8a36ec323867e39cff0968b48d45917ca98a507506dad2f067b206a0ee5d83'
SMB_SO_SHA = '02b042413c0dd13c724046068b714e31d9cf60463c157b4b0a0745bdac68e212'

def digest(data):
    return hashlib.sha256(data).hexdigest()

def download(url, expected):
    request = urllib.request.Request(url, headers={'User-Agent': 'VablePlayer-dependency-bootstrap/1'})
    with urllib.request.urlopen(request, timeout=90) as response:
        chunks, size = [], 0
        while True:
            block = response.read(1024 * 1024)
            if not block: break
            size += len(block)
            if size > 64 * 1024 * 1024: raise ValueError('Upstream download exceeded 64 MiB')
            chunks.append(block)
    data = b''.join(chunks)
    if digest(data) != expected: raise ValueError('Upstream SHA-256 mismatch; no dependency installed')
    return data

def restore(path, expected, producer):
    if path.exists():
        if digest(path.read_bytes()) != expected:
            raise ValueError('Existing dependency differs from pinned bytes: ' + path.relative_to(ROOT).as_posix())
        print('Verified ' + path.relative_to(ROOT).as_posix())
        return
    data = producer()
    if digest(data) != expected: raise ValueError('Dependency SHA-256 mismatch')
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, suffix='.tmp', delete=False) as file:
        file.write(data)
        temporary = Path(file.name)
    try: temporary.replace(path)
    finally: temporary.unlink(missing_ok=True)
    print('Restored ' + path.relative_to(ROOT).as_posix())

def smb_binary():
    data = download(SMB_URL, SMB_HAR_SHA)
    if zipfile.is_zipfile(io.BytesIO(data)):
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            names = [n for n in archive.namelist() if n.endswith('/arm64-v8a/libsmb2.so')]
            if len(names) != 1: raise ValueError('Unexpected SMB archive structure')
            return archive.read(names[0])
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as archive:
        members = [m for m in archive if m.isfile() and m.name.endswith('/arm64-v8a/libsmb2.so')]
        if len(members) != 1 or members[0].size > 4 * 1024 * 1024:
            raise ValueError('Unexpected SMB archive structure')
        return archive.extractfile(members[0]).read()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config-only', action='store_true', help='Only initialize unsigned local build profile')
    args = parser.parse_args()
    local = ROOT / 'build-profile.json5'
    if not local.exists():
        shutil.copyfile(ROOT / 'build-profile.example.json5', local)
        print('Initialized ignored unsigned build-profile.json5')
    if not args.config_only:
        restore(ROOT / 'vendor/mpv-arkts-1.0.0.har', MPV_SHA, lambda: download(MPV_URL, MPV_SHA))
        restore(ROOT / 'vendor/libsmb2-6.2/arm64-v8a/libsmb2.so', SMB_SO_SHA, smb_binary)

if __name__ == '__main__': main()
