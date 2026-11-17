#!/bin/zsh
# Prepara la descarga para GitHub: app universal (Apple Silicon + Intel) en un zip.
# Uso: ./release.sh   →   build/release/Despierto.zip
set -e
cd "$(dirname "$0")"

./build.sh >/dev/null   # se asegura de que el icono existe

OUT="build/release"
APP="$OUT/Despierto.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

for ARCH in arm64 x86_64; do
  echo "🔨 Compilando para $ARCH…"
  swiftc -O -swift-version 5 -parse-as-library -target "$ARCH-apple-macos13" \
    -F /System/Library/PrivateFrameworks -framework DisplayServices \
    main.swift -o "$OUT/Despierto-$ARCH"
done
lipo -create "$OUT/Despierto-arm64" "$OUT/Despierto-x86_64" -output "$APP/Contents/MacOS/Despierto"
rm "$OUT"/Despierto-arm64 "$OUT"/Despierto-x86_64

codesign --force --sign - "$APP" >/dev/null 2>&1
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Despierto.zip"

echo "✅ Listo: $PWD/$OUT/Despierto.zip ($(lipo -archs "$APP/Contents/MacOS/Despierto"))"
