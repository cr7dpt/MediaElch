#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

BUILD_DIR="${1:-$PROJECT_DIR/build}"
QT_PREFIX="$(brew --prefix qt)"

cmake --build "$BUILD_DIR" --parallel 8

PACKAGE_DIR="$(mktemp -d "$BUILD_DIR/package-arm64.XXXXXX")"
APP="$PACKAGE_DIR/MediaElch.app"

ditto "$BUILD_DIR/MediaElch.app" "$APP"

cp "$(brew --prefix libmediainfo)/lib/libmediainfo.0.dylib" \
   "$APP/Contents/MacOS/"
cp "$(brew --prefix ffmpeg)/bin/ffmpeg" \
   "$APP/Contents/MacOS/"

QT_TRANSLATIONS="$("$QT_PREFIX/bin/qtpaths" --query QT_INSTALL_TRANSLATIONS)"
mkdir -p "$APP/Contents/translations"
cp "$QT_TRANSLATIONS"/qt*.qm "$APP/Contents/translations/"

"$QT_PREFIX/bin/macdeployqt" "$APP" \
  -executable="$APP/Contents/MacOS/ffmpeg" \
  -executable="$APP/Contents/MacOS/libmediainfo.0.dylib" \
  -verbose=1

install_name_tool -id '@loader_path/libmediainfo.0.dylib' \
  "$APP/Contents/MacOS/libmediainfo.0.dylib"

python3 - "$APP" <<'PY'
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
problems = []
count = 0

for path in root.rglob("*"):
    if not path.is_file() or path.is_symlink():
        continue
    kind = subprocess.check_output(["file", "-b", str(path)], text=True)
    if "Mach-O" not in kind:
        continue
    count += 1
    ids = subprocess.run(
        ["otool", "-D", str(path)], capture_output=True, text=True,
        check=True
    ).stdout.splitlines()[1:]
    ids = {line.strip() for line in ids}
    links = subprocess.check_output(["otool", "-L", str(path)], text=True)
    for line in links.splitlines()[1:]:
        dep = line.strip().split(" (compatibility version", 1)[0]
        if dep in ids:
            continue
        if dep.startswith(("/opt/homebrew/", "/Users/", "/usr/local/")):
            problems.append(f"{path.relative_to(root)}: {dep}")

print(f"{count} binaires examinés.")
if problems:
    print("\n".join(problems))
    sys.exit("Packaging interrompu : dépendances externes restantes.")
print("Contrôle des chemins de dépendances réussi.")
PY

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

"$APP/Contents/MacOS/ffmpeg" -version > "$PACKAGE_DIR/ffmpeg-version.txt"

printf '\nApplication préparée :\n%s\n' "$APP"
printf '\nCompilation depuis le commit :\n'
git rev-parse HEAD
