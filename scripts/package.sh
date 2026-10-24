#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
TASK_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
# Packaging never rebuilds/resigns the app that is being validated.
codesign --verify --strict dist/Flowmori.app
TASK_ARCH="$(lipo -archs dist/Flowmori.app/Contents/MacOS/Flowmori)"
TASK_ARCH="${TASK_ARCH// /-}"
ditto -c -k --keepParent dist/Flowmori.app "dist/Flowmori-$TASK_VERSION-$TASK_ARCH.zip"
python3 - "$TASK_VERSION" <<'PY'
import pathlib,subprocess,sys,zipfile
root=pathlib.Path.cwd()
# Package the working-tree contents of tracked public source files only.
# Local notes, ignored files and untracked scratch files cannot enter a release.
tracked=subprocess.check_output(['git','ls-files','--cached','-z'],cwd=root).decode().split('\0')
root_files={'Package.swift','README.md','LICENSE','.gitignore'}
source_dirs={'Resources','Sources','Tests','scripts','docs','img'}
files=[]
for name in sorted(set(tracked)-{''}):
    relative=pathlib.PurePosixPath(name)
    if name not in root_files and relative.parts[0] not in source_dirs:
        continue
    if relative.suffix in {'.log','.pyc'} or any(part in {'.DS_Store','__pycache__'} for part in relative.parts):
        continue
    file=root/name
    if file.is_symlink() or not file.is_file():
        raise SystemExit(f'Expected regular source file: {name}')
    files.append((file,'Flowmori/'+name))
for required in root_files | {'docs/TESTING.md','img/flowmori-app-icon.png','img/flowmori-menu-icon.png'}:
    if required not in tracked:
        raise SystemExit(f'Stage required source file before packaging: {required}')
with zipfile.ZipFile(root/'dist'/f'Flowmori-{sys.argv[1]}-source.zip','w',zipfile.ZIP_DEFLATED) as archive:
    for file,name in files:
        info=zipfile.ZipInfo.from_file(file,name)
        info.compress_type=zipfile.ZIP_DEFLATED
        archive.writestr(info,file.read_bytes())
print('Packaged app and source archives in dist/.')
PY
