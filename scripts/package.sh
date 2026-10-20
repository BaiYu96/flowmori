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
import pathlib,sys,zipfile
root=pathlib.Path.cwd()
with zipfile.ZipFile(root/'dist'/f'Flowmori-{sys.argv[1]}-source.zip','w',zipfile.ZIP_DEFLATED) as archive:
    for name in ['Package.swift','README.md','LICENSE','.gitignore','Resources','Sources','Tests','scripts','docs']:
        path=root/name
        files=sorted(path.rglob('*')) if path.is_dir() else [path]
        for file in files:
            if file.is_file() and '.DS_Store' not in file.parts and '__pycache__' not in file.parts:
                info=zipfile.ZipInfo.from_file(file,'Flowmori/'+str(file.relative_to(root)))
                info.compress_type=zipfile.ZIP_DEFLATED
                archive.writestr(info,file.read_bytes())
print('Packaged app and source archives in dist/.')
PY
