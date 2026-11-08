#!/usr/bin/env python3
"""Check the distributable, including the SQLite library loaded on this Mac."""
import ctypes
import plistlib
import re
from pathlib import Path
import subprocess
import sys


def verify(bundle: Path) -> None:
    bundle = bundle.resolve()
    contents = bundle / 'Contents'
    with (contents / 'Info.plist').open('rb') as source:
        info = plistlib.load(source)
    assert info['CFBundleName'] == 'SyncTune', info
    assert info['LSMinimumSystemVersion'] == '12.0', info
    assert not info.get('NSAppTransportSecurity', {}).get('NSAllowsArbitraryLoads', False)
    binaries = [contents / 'MacOS' / info['CFBundleExecutable']]
    binaries += [contents / 'Frameworks' / f'{name}.framework' / name for name in ('App', 'FlutterMacOS')]
    frameworks = contents / 'Frameworks'
    sqlite = list(frameworks.glob('*sqlite*.framework/*sqlite*'))
    sqlite += list(frameworks.rglob('*sqlite*.dylib'))
    sqlite = sorted({binary.resolve() for binary in sqlite if binary.is_file()})
    assert sqlite, 'SQLite native asset is missing from the app bundle'
    binaries += sqlite
    for binary in binaries:
        architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
        assert {'arm64', 'x86_64'} <= set(architectures), f'{binary}: {architectures}'
        commands = subprocess.check_output(['otool', '-l', str(binary)], text=True)
        minimums = re.findall(r'\bminos ([0-9.]+)', commands)
        minimums += re.findall(
            r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([0-9.]+)', commands)
        assert minimums, f'No minimum macOS version found in {binary}'
        for minimum in minimums:
            version = tuple((list(map(int, minimum.split('.'))) + [0, 0])[:3])
            assert version <= (12, 0, 0), f'{binary} requires macOS {minimum}'
        print(f'{binary.relative_to(bundle)}: {" + ".join(architectures)}')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
    signed_entitlements = subprocess.check_output(
        ['codesign', '-d', '--entitlements', ':-', str(bundle)], stderr=subprocess.DEVNULL)
    if signed_entitlements.strip():
        entitlements = plistlib.loads(signed_entitlements)
        assert not entitlements.get('com.apple.security.app-sandbox', False)
    library = ctypes.CDLL(str(sqlite[0].resolve()))
    library.sqlite3_libversion.restype = ctypes.c_char_p
    library.sqlite3_open.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    library.sqlite3_close.argtypes = [ctypes.c_void_p]
    database = ctypes.c_void_p()
    assert library.sqlite3_open(b':memory:', ctypes.byref(database)) == 0
    assert library.sqlite3_close(database) == 0
    print(f'Bundled SQLite {library.sqlite3_libversion().decode()}: opened and closed a database')


if __name__ == '__main__':
    verify(Path(sys.argv[1] if len(sys.argv) > 1 else 'build/macos/Build/Products/Release/SyncTune.app'))
