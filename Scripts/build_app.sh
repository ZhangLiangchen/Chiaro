#!/usr/bin/env bash
set -euo pipefail

CONFIG="release"
APP_VERSION="${CHIARO_VERSION:-1.1.0}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) CONFIG="debug"; shift ;;
    --release) CONFIG="release"; shift ;;
    --version)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "ERROR: --version requires a value" >&2
        exit 1
      fi
      APP_VERSION="$2"
      shift 2
      ;;
    --version=*)
      APP_VERSION="${1#--version=}"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--debug|--release] [--version <ver>]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Chiaro"
BUNDLE_NAME="Chiaro_ChiaroCore.bundle"
APP_DIR="$ROOT_DIR/${APP_NAME}.app"

cd "$ROOT_DIR"

echo "==> Building ${APP_NAME} (${CONFIG})..."
swift build -c "$CONFIG" --product "$APP_NAME"

CONFIG_CAP="Release"
if [[ "$CONFIG" == "debug" ]]; then
  CONFIG_CAP="Debug"
fi

locate_product() {
  local name="$1"
  local candidates=(
    "$ROOT_DIR/.build/$CONFIG/$name"
    "$ROOT_DIR/.build/out/Products/$CONFIG_CAP/$name"
    "$ROOT_DIR/.build/arm64-apple-macosx/$CONFIG/$name"
  )
  for cand in "${candidates[@]}"; do
    if [[ -e "$cand" ]]; then
      echo "$cand"
      return 0
    fi
  done
  return 1
}

BIN_PATH="$(locate_product "$APP_NAME" || true)"
BUNDLE_PATH="$(locate_product "$BUNDLE_NAME" || true)"

if [[ -z "$BIN_PATH" || ! -f "$BIN_PATH" ]]; then
  echo "ERROR: Built executable '$APP_NAME' not found for configuration '$CONFIG'." >&2
  exit 1
fi

if [[ -z "$BUNDLE_PATH" || ! -d "$BUNDLE_PATH" ]]; then
  echo "ERROR: Built resource bundle '$BUNDLE_NAME' not found for configuration '$CONFIG'." >&2
  exit 1
fi

STAGING_PARENT="$(mktemp -d "${ROOT_DIR}/.${APP_NAME}_app_staging.XXXXXX")"
STAGING_APP="${STAGING_PARENT}/${APP_NAME}.app"
BACKUP_APP=""

cleanup() {
  if [[ -n "${BACKUP_APP:-}" && -d "$BACKUP_APP" && ! -d "$APP_DIR" ]]; then
    mv "$BACKUP_APP" "$APP_DIR" || true
  fi
  rm -rf "$STAGING_PARENT" || true
}
trap cleanup EXIT

mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources" "$STAGING_APP/Contents/Frameworks"

cp "$BIN_PATH" "$STAGING_APP/Contents/MacOS/$APP_NAME"
chmod 755 "$STAGING_APP/Contents/MacOS/$APP_NAME"

cp -R "$BUNDLE_PATH" "$STAGING_APP/Contents/Resources/$BUNDLE_NAME"

APP_ICON_SRC="$ROOT_DIR/Assets/AppIcon.icns"
if [[ ! -f "$APP_ICON_SRC" ]]; then
  echo "ERROR: App icon missing at $APP_ICON_SRC" >&2
  exit 1
fi
cp "$APP_ICON_SRC" "$STAGING_APP/Contents/Resources/AppIcon.icns"

# Verify critical bundled resources (Shaders.metal, Presets, and LensfunDB XMLs)
APP_RES_BUNDLE="$STAGING_APP/Contents/Resources/$BUNDLE_NAME"
if ! find "$APP_RES_BUNDLE" -name 'Shaders.metal' | grep -q .; then
  echo "ERROR: Shaders.metal missing from $APP_RES_BUNDLE" >&2
  exit 1
fi
if ! find "$APP_RES_BUNDLE" -path '*/Presets/*.json' | grep -q .; then
  echo "ERROR: Preset JSON files missing from $APP_RES_BUNDLE" >&2
  exit 1
fi
if find "$ROOT_DIR/Sources/ChiaroCore/Resources/LensfunDB" -maxdepth 1 -name '*.xml' 2>/dev/null | grep -q .; then
  if ! find "$APP_RES_BUNDLE" -path '*/LensfunDB/*.xml' | grep -q .; then
    echo "ERROR: LensfunDB XML files missing from $APP_RES_BUNDLE" >&2
    exit 1
  fi
fi

# Bundle GPL-3.0-compatible non-system dylibs (SVT-AV1 / libaom / dav1d / libvmaf / glib if dynamically linked)
# recursively so Chiaro.app runs standalone on any Apple Silicon Mac without Homebrew.
echo "==> Bundling standalone dynamic libraries into Contents/Frameworks..."
FRAMEWORKS_DIR="$STAGING_APP/Contents/Frameworks"
MAIN_EXEC="$STAGING_APP/Contents/MacOS/$APP_NAME"

resolve_rpath_dylib() {
  local rel="$1"
  local cand
  for cand in "$ROOT_DIR/Vendor/install/lib/$rel" /opt/homebrew/opt/*/lib/"$rel"; do
    if [[ -f "$cand" ]]; then
      echo "$cand"
      return 0
    fi
  done
  return 1
}

bundle_deps_for() {
  local target="$1"
  local is_main="$2"
  local dep
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    case "$dep" in
      /System/*|/usr/lib/*|@loader_path/*|@executable_path/*) continue ;;
      @rpath/libswift*) continue ;;
      @rpath/*)
        local rel="${dep#@rpath/}"
        local resolved_rpath
        resolved_rpath="$(resolve_rpath_dylib "$rel" || true)"
        if [[ -z "$resolved_rpath" || ! -f "$resolved_rpath" ]]; then
          continue
        fi
        local base
        base="$(basename "$resolved_rpath")"
        local dest="$FRAMEWORKS_DIR/$base"
        if [[ ! -f "$dest" ]]; then
          cp -L "$resolved_rpath" "$dest"
          chmod 755 "$dest"
          install_name_tool -id "@loader_path/$base" "$dest"
          bundle_deps_for "$dest" 0
        fi
        if [[ "$is_main" -eq 1 ]]; then
          install_name_tool -change "$dep" "@executable_path/../Frameworks/$base" "$target"
        else
          install_name_tool -change "$dep" "@loader_path/$base" "$target"
        fi
        ;;
      /*)
        if [[ ! -f "$dep" ]]; then
          echo "ERROR: Missing dynamic library dependency: $dep" >&2
          exit 1
        fi
        local base
        base="$(basename "$dep")"
        local dest="$FRAMEWORKS_DIR/$base"
        if [[ ! -f "$dest" ]]; then
          cp -L "$dep" "$dest"
          chmod 755 "$dest"
          install_name_tool -id "@loader_path/$base" "$dest"
          bundle_deps_for "$dest" 0
        fi
        if [[ "$is_main" -eq 1 ]]; then
          install_name_tool -change "$dep" "@executable_path/../Frameworks/$base" "$target"
        else
          install_name_tool -change "$dep" "@loader_path/$base" "$target"
        fi
        ;;
    esac
  done < <(otool -L "$target" | tail -n +2 | awk '{print $1}')
}

bundle_deps_for "$MAIN_EXEC" 1

# Verify zero /opt/homebrew or /usr/local dylib references remain inside the bundle
for macho in "$MAIN_EXEC" "$FRAMEWORKS_DIR"/*.dylib; do
  [[ -f "$macho" ]] || continue
  if otool -L "$macho" | tail -n +2 | awk '{print $1}' | grep -Eq '^/(opt/homebrew|usr/local)/'; then
    echo "ERROR: Unbundled external dylib reference remains in $macho:" >&2
    otool -L "$macho" >&2
    exit 1
  fi
done

cat <<PLIST > "$STAGING_APP/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Chiaro</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeExtensions</key>
			<array>
				<string>arw</string>
				<string>ARW</string>
			</array>
			<key>CFBundleTypeName</key>
			<string>Sony ARW RAW Image</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>com.sony.arw-raw-image</string>
			</array>
		</dict>
	</array>
	<key>CFBundleExecutable</key>
	<string>Chiaro</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.zhangliangchen.chiaro</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Chiaro</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${APP_VERSION}</string>
	<key>CFBundleVersion</key>
	<string>2</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

find "$STAGING_APP" \( -name '.DS_Store' -o -name '*.tmp' \) -delete

echo "==> Validating Info.plist..."
plutil -lint "$STAGING_APP/Contents/Info.plist"

echo "==> Code signing staging bundle (frameworks first, then app)..."
for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
  [[ -f "$dylib" ]] || continue
  codesign --force --sign - "$dylib"
done
codesign --force --deep --sign - "$STAGING_APP"
codesign --verify --deep --strict "$STAGING_APP"

if [[ -e "$APP_DIR" ]]; then
  BACKUP_APP="${STAGING_PARENT}/backup_${APP_NAME}.app"
  mv "$APP_DIR" "$BACKUP_APP"
fi

mv "$STAGING_APP" "$APP_DIR"
if [[ -n "$BACKUP_APP" && -d "$BACKUP_APP" ]]; then
  rm -rf "$BACKUP_APP"
  BACKUP_APP=""
fi

find "$APP_DIR" \( -name '.DS_Store' -o -name '*.tmp' \) -delete

echo "==> Re-verifying installed bundle..."
plutil -lint "$APP_DIR/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "==> Running license & Mach-O linkage audit..."
bash "$ROOT_DIR/Scripts/verify_licenses.sh" --require-binaries

echo "==> Built standalone ${APP_DIR} successfully."
