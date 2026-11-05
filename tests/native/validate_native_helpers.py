from pathlib import Path
import ctypes as c
import argparse
import atexit
import os
import platform
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description='Compile and run actual product C helper fixtures on the host; no device/network access.')
parser.add_argument('--project-root', default=os.environ.get('NAS_PLAYER_ROOT'), help='NasPlayerHarmony root; defaults to this script parent project')
parser.add_argument('--cc', default=os.environ.get('CC'), help='C compiler executable, without flags')
parser.add_argument('--ld', default=os.environ.get('LD'), help='Optional lld-link executable for Windows Clang')
args = parser.parse_args()
project = Path(args.project_root).resolve() if args.project_root else Path(__file__).resolve().parents[2]
include = project / 'entry/src/main/cpp/aisubtitle'
for header in ('subtitle_text.h', 'http_range.h', 'local_source.h'):
    if not (include / header).is_file():
        parser.error('Product header not found; set --project-root or NAS_PLAYER_ROOT to NasPlayerHarmony.')
compiler = args.cc or shutil.which('clang') or shutil.which('cc') or shutil.which('gcc')
if not compiler:
    parser.error('No host C compiler found; set CC or --cc to a Clang/GCC executable.')

# Build artifacts stay outside the checkout. Windows Clang can compile these
# freestanding helpers without a Visual Studio CRT/SDK or FFmpeg installation.
temporary = tempfile.TemporaryDirectory(prefix='nas-player-native-fixtures-')
build = Path(temporary.name)
source = Path(__file__).with_name('helper_probe.c').resolve()
library = build / ('helpers.dll' if os.name == 'nt' else 'helpers.dylib' if sys.platform == 'darwin' else 'helpers.so')
try:
    version = subprocess.run([compiler, '--version'], check=True, capture_output=True, text=True).stdout.lower()
    if os.name == 'nt' and 'clang' in version:
        if c.sizeof(c.c_void_p) != 8:
            parser.error('Windows Clang path requires 64-bit Python.')
        arm = platform.machine().lower() in ('arm64', 'aarch64')
        target = 'aarch64-pc-windows-msvc' if arm else 'x86_64-pc-windows-msvc'
        machine = 'arm64' if arm else 'x64'
        compiler_path = Path(shutil.which(compiler) or compiler).resolve()
        sibling_linker = compiler_path.with_name('lld-link.exe')
        linker = args.ld or (str(sibling_linker) if sibling_linker.is_file() else shutil.which('lld-link'))
        if not linker:
            parser.error('Windows Clang requires lld-link; set LD or --ld.')
        obj = build / 'helpers.obj'
        subprocess.run([compiler, '--target=' + target, '-ffreestanding', '-fno-builtin', '-O0', '-std=c11',
                        '-c', '-I' + str(include), str(source), '-o', str(obj)], check=True)
        subprocess.run([linker, '/dll', '/noentry', '/machine:' + machine, '/nodefaultlib',
                        '/out:' + str(library), str(obj)], check=True)
    else:
        shared = '-dynamiclib' if sys.platform == 'darwin' else '-shared'
        subprocess.run([compiler, shared, '-fPIC', '-O0', '-std=c11', '-I' + str(include),
                        str(source), '-o', str(library)], check=True)
    lib = c.CDLL(str(library))
except BaseException:
    temporary.cleanup()
    raise

def cleanup():
    global lib
    if lib is not None:
        if os.name == 'nt':
            import _ctypes
            _ctypes.FreeLibrary(lib._handle)
        lib = None
    temporary.cleanup()

# This also unloads the DLL on a failed assertion before TemporaryDirectory's
# finalizer runs, keeping generated artifacts out of the project and test ZIP.
atexit.register(cleanup)
lib.ai_plain.argtypes = [c.c_char_p, c.c_size_t, c.c_char_p, c.c_size_t, c.c_int]
lib.ai_plain.restype = c.c_int
lib.ai_interval.argtypes = [c.c_int64, c.c_uint32, c.c_uint32, c.c_int64, c.POINTER(c.c_int64), c.POINTER(c.c_int64)]
lib.ai_interval.restype = c.c_int
lib.ai_range_end.argtypes = [c.c_int64, c.c_int64, c.c_int64, c.POINTER(c.c_int64)]
lib.ai_range_end.restype = c.c_int

lib.ai_fd_source.argtypes = [c.c_char_p, c.POINTER(c.c_int)]
lib.ai_fd_source.restype = c.c_int
for source, expected in [('', None), ('f', None), ('fd://', None), ('fd://0', 0), ('fd://80', 80),
                         ('fd://2147483647', 2147483647), ('fd://2147483648', None), ('fd://-1', None),
                         ('fd://01', None), ('fd://1/path', None), ('fd://1?x', None), ('fdclose://1', None)]:
    result = c.c_int(-1)
    parsed = lib.ai_fd_source(source.encode(), c.byref(result))
    assert (result.value if parsed else None) == expected

def range_end(start, total, expected, chunk=512*1024):
    end = c.c_int64()
    result = lib.ai_range_end(start, total, chunk, c.byref(end))
    assert (end.value if result else None) == expected

range_end(0, 0, 0)
range_end(1, 0, None)
range_end(0, 1, 0)
range_end(0, 100, 99)
range_end(0, 512*1024, 512*1024-1)
range_end(512*1024, 600000, 599999)
range_end(600000, 600000, None)
range_end(600001, 600000, None)
range_end(-1, 600000, None)
range_end(2**32, 2**32+17, 2**32+16)
range_end(2**63-11, 2**63-1, 2**63-2)

def interval(base, start, end, duration, expected):
    a, b = c.c_int64(), c.c_int64()
    result = lib.ai_interval(base, start, end, duration, c.byref(a), c.byref(b))
    assert ((a.value, b.value) if result else None) == expected

interval(10500, 100, 2400, 5000, (10600, 12900))
interval(12000, 0, 0, 2500, (12000, 14500))
interval(12000, 0, 0xFFFFFFFF, 2500, (12000, 14500))
interval(12000, 0, 0, 0, None)
interval(12000, 100, 0, 50, None)
interval(-100, 0, 500, 0, (-100, 400))
interval(2**63 - 3, 0, 500, 0, None)

def plain(text, ass, expected, capacity=16385):
    data = text.encode('utf-8')
    out = c.create_string_buffer(capacity)
    result = lib.ai_plain(data, len(data), out, capacity, ass)
    assert (out.value.decode('utf-8') if result >= 0 else None) == expected

plain('0,0,Default,,0,0,0,,{\\b1}Hello, world{\\b0}\\N第二行\\htext', 1, 'Hello, world\n第二行 text')
plain('Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,Text, with comma', 1, 'Text, with comma')
plain('0,0,Default,,0,0,0,,{\\p1}m 0 0 l 1 1{\\p0}Real', 1, 'Real')
plain('0,0,Default,,0,0,0,,{\\p1}m 0 0 l 1 1', 1, '')
plain('你好{非样式}\nfoo', 0, '你好{非样式}\nfoo')
plain('\ufeff  hello \r\n', 0, 'hello')
plain('0,0,Default,,0,0,0,,{\\k20}歌{\\k20}词', 1, '歌词')
plain('malformed ASS', 1, None)
plain('0,0,Default,,0,0,0,,{\\b1', 1, None)
plain('too long', 0, None, capacity=4)
plain('  \t\r\n ', 0, '')
print('PASS: 41 actual C helper cases (including 12 strict fd URI cases): strict Range discovery/tail/EOF/64-bit boundaries, subtitle millisecond offsets, packet-duration fallback, unknown/overflow rejection, ASS formats, UTF-8, drawing suppression and bounded output. Host helpers only; no device/demux proof.')

cleanup()
