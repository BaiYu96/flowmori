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
# Stage the volume root explicitly so the app and Applications appear together.
# Do not point hdiutil at the app bundle itself or follow the Applications link.
TASK_DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/flowmori-dmg.XXXXXX")"
trap 'rm -rf "$TASK_DMG_STAGE"' EXIT
ditto dist/Flowmori.app "$TASK_DMG_STAGE/Flowmori.app"
ln -s /Applications "$TASK_DMG_STAGE/Applications"
cat > "$TASK_DMG_STAGE/安装说明 - 拖动 Flowmori 到 Applications.txt" <<'INSTALL'
安装 Flowmori

将此窗口中的 Flowmori.app 拖到 Applications 文件夹，即可安装。
复制完成后，请从「应用程序」打开 Flowmori，再推出此磁盘映像。

更新时，请先退出正在运行的 Flowmori，再拖入并选择替换。

Install Flowmori

Drag Flowmori.app onto Applications in this window.
When copying finishes, open Flowmori from Applications and eject this disk image.
To update, quit Flowmori first, then drag it into Applications and choose Replace.
INSTALL
hdiutil create -volname "Flowmori - 拖入 Applications" \
    -srcfolder "$TASK_DMG_STAGE" \
    -ov -format UDZO "dist/Flowmori-$TASK_VERSION-$TASK_ARCH.dmg"
hdiutil verify "dist/Flowmori-$TASK_VERSION-$TASK_ARCH.dmg"
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
print('Packaged installation DMG, app ZIP and source ZIP in dist/.')
PY
