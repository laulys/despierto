#!/bin/zsh
# Compila Despierto.app. Uso: ./build.sh
set -e
cd "$(dirname "$0")"

# El icono solo se dibuja la primera vez (o si borras AppIcon.icns).
if [ ! -f AppIcon.icns ]; then
  swift icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o AppIcon.icns
fi

APP="build/Despierto.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp guard.plist "$APP/Contents/Library/LaunchAgents/local.despierto.guard.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos13" \
  main.swift -o "$APP/Contents/MacOS/Despierto"

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "✅ Listo: $PWD/$APP"
