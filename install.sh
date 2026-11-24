#!/bin/bash
# Instala Despierto ☕: descarga la última versión y la copia a Aplicaciones.
#
#   curl -fsSL https://raw.githubusercontent.com/laulys/despierto/main/install.sh | bash
#
# Lee este script antes de ejecutarlo si quieres: descarga el zip de la versión de
# abajo, comprueba que es exactamente el publicado (SHA-256), lo copia en
# Aplicaciones y abre la app. Si no coincide, no instala nada.
set -euo pipefail

# release.sh actualiza estas dos líneas en cada versión
VERSION="v2.3.0"
SHA256="11888465ebca88608edaed5b009c771ccdb631cd104b5f70f8b6aed6480362ba"
URL="https://github.com/laulys/despierto/releases/download/$VERSION/Despierto.zip"
DEST="${DESPIERTO_DEST:-/Applications}"

if [ "$(uname)" != "Darwin" ]; then
  echo "Despierto solo funciona en macOS." >&2
  exit 1
fi

# Si no se puede escribir en /Applications, usamos la carpeta Aplicaciones del usuario
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
fi
mkdir -p "$DEST"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "☕ Descargando Despierto ${VERSION}…"
curl -fsSL "$URL" -o "$TMP/Despierto.zip"
if ! echo "$SHA256  $TMP/Despierto.zip" | shasum -a 256 -c - >/dev/null 2>&1; then
  echo "❌ El archivo descargado no coincide con el publicado. No se instala nada." >&2
  exit 1
fi
ditto -x -k "$TMP/Despierto.zip" "$TMP"

# Si ya estaba abierta (esta misma copia), la cerramos para poder reemplazarla
pkill -f "$DEST/Despierto.app/Contents/MacOS/Despierto" 2>/dev/null || true
rm -rf "$DEST/Despierto.app"
cp -R "$TMP/Despierto.app" "$DEST/"

echo "✅ Instalada en $DEST/Despierto.app"
echo "   Búscala arriba, en la barra de menú (una tacita de café)."

if [ -z "${DESPIERTO_NO_OPEN:-}" ]; then
  open "$DEST/Despierto.app"
fi
