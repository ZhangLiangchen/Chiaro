#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-1.0.0}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
CLI_NAME="chiaro-cli"
APP_NAME="Chiaro"
BUNDLE_NAME="Chiaro_ChiaroCore.bundle"

cd "$ROOT_DIR"

echo "==> Building release CLI (${CLI_NAME})..."
swift build -c release --product "$CLI_NAME"

echo "==> Building standalone ${APP_NAME}.app..."
bash "$ROOT_DIR/Scripts/build_app.sh" --release

locate_release_product() {
  local name="$1"
  for cand in \
    "$ROOT_DIR/.build/release/$name" \
    "$ROOT_DIR/.build/out/Products/Release/$name" \
    "$ROOT_DIR/.build/arm64-apple-macosx/release/$name"; do
    if [[ -e "$cand" ]]; then
      echo "$cand"
      return 0
    fi
  done
  return 1
}

CLI_BIN="$(locate_release_product "$CLI_NAME")"
BUNDLE_PATH="$(locate_release_product "$BUNDLE_NAME")"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# 1. Package standalone Chiaro.app archive (preserves macOS bundle metadata & code signature)
APP_ZIP="$DIST_DIR/${APP_NAME}-${VERSION}-macos-arm64.zip"
echo "==> Packaging ${APP_ZIP}..."
ditto -c -k --sequesterRsrc --keepParent "$ROOT_DIR/${APP_NAME}.app" "$APP_ZIP"

# 2. Package standalone chiaro-cli archive (bundles BSD codec dylibs + resource bundle + chiaro symlink)
CLI_PKG_NAME="chiaro-cli-${VERSION}-macos-arm64"
CLI_STAGE="$(mktemp -d "${ROOT_DIR}/.${CLI_NAME}_staging.XXXXXX")"
trap 'rm -rf "$CLI_STAGE"' EXIT

PKG_DIR="$CLI_STAGE/$CLI_PKG_NAME"
mkdir -p "$PKG_DIR/bin" "$PKG_DIR/lib"

cp "$CLI_BIN" "$PKG_DIR/bin/$CLI_NAME"
chmod 755 "$PKG_DIR/bin/$CLI_NAME"
ln -s "$CLI_NAME" "$PKG_DIR/bin/chiaro"
cp -R "$BUNDLE_PATH" "$PKG_DIR/bin/$BUNDLE_NAME"
cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$ROOT_DIR/README.md" "$PKG_DIR/"

bundle_cli_deps() {
  local target="$1"
  local is_main="$2"
  local dep
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    case "$dep" in
      /System/*|/usr/lib/*|@*) continue ;;
      /*)
        local base
        base="$(basename "$dep")"
        local dest="$PKG_DIR/lib/$base"
        if [[ ! -f "$dest" ]]; then
          cp -L "$dep" "$dest"
          chmod 755 "$dest"
          install_name_tool -id "@loader_path/$base" "$dest"
          bundle_cli_deps "$dest" 0
        fi
        if [[ "$is_main" -eq 1 ]]; then
          install_name_tool -change "$dep" "@executable_path/../lib/$base" "$target"
        else
          install_name_tool -change "$dep" "@loader_path/$base" "$target"
        fi
        ;;
    esac
  done < <(otool -L "$target" | tail -n +2 | awk '{print $1}')
}

bundle_cli_deps "$PKG_DIR/bin/$CLI_NAME" 1

for dylib in "$PKG_DIR/lib"/*.dylib; do
  [[ -f "$dylib" ]] || continue
  codesign --force --sign - "$dylib"
done
codesign --force --sign - "$PKG_DIR/bin/$CLI_NAME"
codesign --verify --strict "$PKG_DIR/bin/$CLI_NAME"

# Verify zero Homebrew paths remain in standalone CLI package
for macho in "$PKG_DIR/bin/$CLI_NAME" "$PKG_DIR/lib"/*.dylib; do
  if otool -L "$macho" | tail -n +2 | awk '{print $1}' | grep -Eq '^/(opt/homebrew|usr/local)/'; then
    echo "ERROR: Unbundled external dylib reference remains in $macho" >&2
    otool -L "$macho" >&2
    exit 1
  fi
done

# Smoke-test standalone CLI from staging directory
echo "==> Smoke-testing standalone CLI (--list-presets)..."
"$PKG_DIR/bin/$CLI_NAME" --list-presets

CLI_TAR="$DIST_DIR/${CLI_PKG_NAME}.tar.gz"
echo "==> Packaging ${CLI_TAR}..."
tar -czf "$CLI_TAR" -C "$CLI_STAGE" "$CLI_PKG_NAME"

# 3. Generate SHA256SUMS.txt
echo "==> Generating SHA256SUMS.txt..."
(
  cd "$DIST_DIR"
  shasum -a 256 "$(basename "$APP_ZIP")" "$(basename "$CLI_TAR")" > SHA256SUMS.txt
  cat SHA256SUMS.txt
)

echo "==> Release artifacts ready in $DIST_DIR:"
ls -lh "$DIST_DIR"
