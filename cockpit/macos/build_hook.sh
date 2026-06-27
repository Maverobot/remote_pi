#!/bin/bash
# Compila o helper `cockpit-hook` (tool/cockpit_hook.dart) e o coloca no lugar
# certo, assinado. Dois modos:
#
#   ./macos/build_hook.sh dev
#     Compila para ~/.cockpit/bin/cockpit-hook (para `flutter run` / testes E2E).
#
#   ./macos/build_hook.sh                (sem args, ou rodado pelo Xcode)
#     Modo bundle: compila e copia para
#       ${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources/cockpit-hook
#     e code-signa com ${EXPANDED_CODE_SIGN_IDENTITY} (a mesma da app).
#
# Para produção, adicione este script como **Run Script** build phase no target
# Runner (Xcode), DEPOIS de "Bundle Dart" / antes de "Code Sign". Variáveis
# BUILT_PRODUCTS_DIR/PRODUCT_NAME/EXPANDED_CODE_SIGN_IDENTITY vêm do Xcode.
set -euo pipefail

# Raiz do projeto cockpit (este script vive em cockpit/macos/).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/tool/cockpit_hook.dart"

compile() {
  local out="$1"
  mkdir -p "$(dirname "$out")"
  echo "[build_hook] compilando $SRC -> $out"
  dart compile exe "$SRC" -o "$out"
  chmod +x "$out"
}

sign() {
  local target="$1"
  local identity="${EXPANDED_CODE_SIGN_IDENTITY:--}" # '-' = ad-hoc se não houver
  echo "[build_hook] codesign ($identity) $target"
  codesign --force --options runtime --timestamp=none -s "$identity" "$target" || \
    codesign --force -s - "$target"
}

mode="${1:-bundle}"
if [ "$mode" = "dev" ]; then
  compile "$HOME/.cockpit/bin/cockpit-hook"
  echo "[build_hook] dev OK"
  exit 0
fi

# Modo bundle (Xcode).
: "${BUILT_PRODUCTS_DIR:?precisa rodar pelo Xcode (BUILT_PRODUCTS_DIR ausente)}"
: "${PRODUCT_NAME:?PRODUCT_NAME ausente}"
DEST="$BUILT_PRODUCTS_DIR/$PRODUCT_NAME.app/Contents/Resources/cockpit-hook"
compile "$DEST"
sign "$DEST"
echo "[build_hook] bundle OK -> $DEST"
