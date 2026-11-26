#!/usr/bin/env bash
set -euo pipefail

# Build GPL-3.0-compatible native dependencies for Chiaro V1.1:
#   - LibRaw 0.22.3 (LGPL-2.1 elected, static reentrant libraw_r.a, built-in AHD/DCB/DHT/AAHD)
#   - CarVac/librtprocess 0.12.0 (GPL-3.0-or-later, AMaZE & LMMSE via LibRaw callbacks)
#   - Lensfun 0.3.4 (LGPL-3.0-only, static liblensfun.a + CC-BY-SA-3.0 XML database)
#   - libultrahdr 2.0.2 (Apache-2.0, JPEG-only, ISO + XMP enabled, HEIF disabled)
#   - libavif 1.4.2 (BSD-2, SVT-AV1 + libaom + dav1d + libyuv LOCAL)
# Produces static libraries in Vendor/install/, XCFrameworks in Vendor/XCFrameworks/,
# and offline LensfunDB resources in Sources/ChiaroCore/Resources/LensfunDB/.

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      echo "Usage: $0 [--force]"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/Vendor"
CACHE_DIR="$VENDOR_DIR/.cache"
SRC_DIR="$VENDOR_DIR/.src"
BUILD_DIR="$VENDOR_DIR/.build"
INSTALL_DIR="$VENDOR_DIR/install"
XCF_DIR="$VENDOR_DIR/XCFrameworks"

export MACOSX_DEPLOYMENT_TARGET=15.0
ARCH="arm64"
JOBS="$(sysctl -n hw.ncpu)"

# Ensure clean compiler/linker environment without stray /opt/homebrew/lib
unset LDFLAGS CPPFLAGS CFLAGS CXXFLAGS LIBRARY_PATH CPATH PKG_CONFIG_LIBDIR

mkdir -p "$CACHE_DIR" "$SRC_DIR" "$BUILD_DIR" "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" "$INSTALL_DIR/include" "$XCF_DIR"

log() {
  echo "[Vendor/build_deps] $*"
}

write_xcframework_plist() {
  local plist_path="$1"
  local lib_name="$2"
  cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64</string>
			<key>LibraryPath</key>
			<string>${lib_name}</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
EOF
}

fetch_tarball() {
  local url="$1"
  local dest="$2"
  if [[ -f "$dest" ]]; then
    if gzip -t "$dest" 2>/dev/null; then
      log "Using cached tarball: $dest"
      return 0
    fi
    rm -f "$dest"
  fi
  log "Downloading $url -> $dest"
  curl -fsSL --retry 3 "$url" -o "$dest"
  gzip -t "$dest"
}

ensure_brew_pkg() {
  local pkg="$1"
  if ! brew list --versions "$pkg" >/dev/null 2>&1; then
    log "Installing Homebrew package: $pkg"
    HOMEBREW_NO_AUTO_UPDATE=1 brew install "$pkg"
  elif [[ -n "$(HOMEBREW_NO_AUTO_UPDATE=1 brew outdated --quiet "$pkg" 2>/dev/null || true)" ]]; then
    log "Upgrading Homebrew package: $pkg"
    yes | HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade "$pkg"
  else
    log "Homebrew package $pkg is up-to-date: $(brew list --versions "$pkg")"
  fi
}

log "Step 1/6: Provisioning build tools and GPL-3.0-compatible dependencies via Homebrew..."
for pkg in cmake pkgconf svt-av1 aom dav1d jpeg-turbo libpng libultrahdr glib gettext pcre2; do
  ensure_brew_pkg "$pkg"
done

OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
MAC_PC_DIR="/opt/homebrew/Library/Homebrew/os/mac/pkgconfig/${OS_MAJOR}"
if [[ ! -d "$MAC_PC_DIR" ]]; then
  MAC_PC_DIR="/opt/homebrew/Library/Homebrew/os/mac/pkgconfig/15"
fi

# Strictly isolated PKG_CONFIG_PATH and CMAKE_PREFIX_PATH (NEVER /opt/homebrew/lib)
export PKG_CONFIG_PATH="/opt/homebrew/opt/svt-av1/lib/pkgconfig:/opt/homebrew/opt/aom/lib/pkgconfig:/opt/homebrew/opt/dav1d/lib/pkgconfig:/opt/homebrew/opt/jpeg-turbo/lib/pkgconfig:/opt/homebrew/opt/libpng/lib/pkgconfig:/opt/homebrew/opt/glib/lib/pkgconfig:/opt/homebrew/opt/gettext/lib/pkgconfig:/opt/homebrew/opt/pcre2/lib/pkgconfig:${MAC_PC_DIR}"
export CMAKE_PREFIX_PATH="/opt/homebrew/opt/svt-av1:/opt/homebrew/opt/aom:/opt/homebrew/opt/dav1d:/opt/homebrew/opt/jpeg-turbo:/opt/homebrew/opt/libpng:/opt/homebrew/opt/glib:/opt/homebrew/opt/gettext:/opt/homebrew/opt/pcre2"

# ------------------------------------------------------------------------------
# Step 2/6: LibRaw 0.22.3 (LGPL-2.1 elected, static reentrant libraw_r.a)
# ------------------------------------------------------------------------------
LIBRAW_VER="0.22.3"
LIBRAW_TAR="$CACHE_DIR/LibRaw-${LIBRAW_VER}.tar.gz"
LIBRAW_SRC="$SRC_DIR/LibRaw-${LIBRAW_VER}"
LIBRAW_XCF="$XCF_DIR/LibRaw.xcframework"

if [[ "$FORCE" -eq 1 || ! -f "$INSTALL_DIR/lib/libraw_r.a" || ! -f "$LIBRAW_XCF/macos-arm64/libraw_r.a" ]]; then
  log "Step 2/6: Building LibRaw ${LIBRAW_VER} (LGPL-2.1 elected, built-in AHD/DCB/DHT/AAHD)..."
  fetch_tarball "https://www.libraw.org/data/LibRaw-${LIBRAW_VER}.tar.gz" "$LIBRAW_TAR"
  rm -rf "$LIBRAW_SRC" "$LIBRAW_XCF"
  tar -xzf "$LIBRAW_TAR" -C "$SRC_DIR"

  # License verification (electing LGPL-2.1 side of LibRaw dual license)
  test -f "$LIBRAW_SRC/LICENSE.LGPL"
  test -f "$LIBRAW_SRC/configure"

  pushd "$LIBRAW_SRC" >/dev/null
  CFLAGS="-O3 -fPIC -arch ${ARCH} -mmacosx-version-min=15.0" \
  CXXFLAGS="-O3 -fPIC -arch ${ARCH} -mmacosx-version-min=15.0" \
  ZLIB_CFLAGS=" " \
  ZLIB_LIBS="-lz" \
  ./configure \
    --prefix="$INSTALL_DIR" \
    --disable-shared \
    --enable-static \
    --disable-openmp \
    --disable-examples \
    --disable-lcms \
    --disable-jpeg \
    --enable-zlib
  make -j"$JOBS"
  make install
  popd >/dev/null

  mkdir -p "$LIBRAW_XCF/macos-arm64/Headers/libraw"
  cp "$INSTALL_DIR/lib/libraw_r.a" "$LIBRAW_XCF/macos-arm64/libraw_r.a"
  cp -R "$INSTALL_DIR/include/libraw/"* "$LIBRAW_XCF/macos-arm64/Headers/libraw/"
  write_xcframework_plist "$LIBRAW_XCF/Info.plist" "libraw_r.a"
else
  log "Step 2/6: LibRaw already built (pass --force to rebuild)."
fi

# ------------------------------------------------------------------------------
# Step 3/6: CarVac/librtprocess 0.12.0 (GPL-3.0-or-later, AMaZE / LMMSE demosaic)
# ------------------------------------------------------------------------------
RTPROC_VER="0.12.0"
RTPROC_TAR="$CACHE_DIR/librtprocess-${RTPROC_VER}.tar.gz"
RTPROC_SRC="$SRC_DIR/librtprocess-${RTPROC_VER}"
RTPROC_BLD="$BUILD_DIR/librtprocess"
RTPROC_XCF="$XCF_DIR/LibRTProcess.xcframework"

if [[ "$FORCE" -eq 1 || ! -f "$INSTALL_DIR/lib/librtprocess.a" || ! -f "$RTPROC_XCF/macos-arm64/librtprocess.a" ]]; then
  log "Step 3/6: Building librtprocess ${RTPROC_VER} (GPL-3.0-or-later, static, OpenMP=OFF)..."
  fetch_tarball "https://github.com/CarVac/librtprocess/archive/refs/tags/${RTPROC_VER}.tar.gz" "$RTPROC_TAR"
  rm -rf "$RTPROC_SRC" "$RTPROC_BLD" "$RTPROC_XCF"
  tar -xzf "$RTPROC_TAR" -C "$SRC_DIR"

  cmake -S "$RTPROC_SRC" -B "$RTPROC_BLD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DOPTION_OMP=OFF

  cmake --build "$RTPROC_BLD" -j"$JOBS"
  cmake --install "$RTPROC_BLD"

  mkdir -p "$RTPROC_XCF/macos-arm64/Headers/rtprocess"
  cp "$INSTALL_DIR/lib/librtprocess.a" "$RTPROC_XCF/macos-arm64/librtprocess.a"
  if [[ -d "$INSTALL_DIR/include/rtprocess" ]]; then
    cp -R "$INSTALL_DIR/include/rtprocess/"* "$RTPROC_XCF/macos-arm64/Headers/rtprocess/"
  elif [[ -f "$INSTALL_DIR/include/librtprocess.h" ]]; then
    cp "$INSTALL_DIR/include/librtprocess.h" "$RTPROC_XCF/macos-arm64/Headers/rtprocess/"
  fi
  write_xcframework_plist "$RTPROC_XCF/Info.plist" "librtprocess.a"
else
  log "Step 3/6: librtprocess already built (pass --force to rebuild)."
fi

# ------------------------------------------------------------------------------
# Step 4/6: Lensfun 0.3.4 (LGPL-3.0-only, static) + offline LensfunDB (CC-BY-SA-3.0)
# ------------------------------------------------------------------------------
LENSFUN_VER="0.3.4"
LENSFUN_TAR="$CACHE_DIR/lensfun-${LENSFUN_VER}.tar.gz"
LENSFUN_SRC="$SRC_DIR/lensfun-${LENSFUN_VER}"
LENSFUN_BLD="$BUILD_DIR/lensfun"
LENSFUN_XCF="$XCF_DIR/LibLensfun.xcframework"
LENSFUN_DB_DEST="$ROOT_DIR/Sources/ChiaroCore/Resources/LensfunDB"
NOISE_PROFILES_DIR="$ROOT_DIR/Sources/ChiaroCore/Resources/NoiseProfiles"

if [[ "$FORCE" -eq 1 || ! -f "$INSTALL_DIR/lib/liblensfun.a" || ! -f "$LENSFUN_XCF/macos-arm64/liblensfun.a" ]]; then
  log "Step 4/6: Building Lensfun ${LENSFUN_VER} (LGPL-3.0-only, static arm64)..."
  fetch_tarball "https://github.com/lensfun/lensfun/archive/refs/tags/v${LENSFUN_VER}.tar.gz" "$LENSFUN_TAR"
  rm -rf "$LENSFUN_SRC" "$LENSFUN_BLD" "$LENSFUN_XCF"
  tar -xzf "$LENSFUN_TAR" -C "$SRC_DIR"

  test -f "$LENSFUN_SRC/docs/lgpl-3.0.txt"
  test -f "$LENSFUN_SRC/docs/cc-by-sa-3.0.txt"

  cmake -S "$LENSFUN_SRC" -B "$LENSFUN_BLD" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_STATIC=ON \
    -DBUILD_TESTS=OFF \
    -DBUILD_LENSTOOL=OFF \
    -DBUILD_FOR_SSE=OFF \
    -DBUILD_FOR_SSE2=OFF \
    -DBUILD_DOC=OFF \
    -DINSTALL_HELPER_SCRIPTS=OFF \
    -DINSTALL_PYTHON_MODULE=OFF \
    -DPYTHON=OFF

  cmake --build "$LENSFUN_BLD" -j"$JOBS"
  cmake --install "$LENSFUN_BLD"

  mkdir -p "$LENSFUN_XCF/macos-arm64/Headers/lensfun"
  cp "$INSTALL_DIR/lib/liblensfun.a" "$LENSFUN_XCF/macos-arm64/liblensfun.a"
  cp -R "$INSTALL_DIR/include/lensfun/"* "$LENSFUN_XCF/macos-arm64/Headers/lensfun/"
  write_xcframework_plist "$LENSFUN_XCF/Info.plist" "liblensfun.a"
else
  log "Step 4/6: Lensfun already built (pass --force to rebuild)."
fi

if [[ "$FORCE" -eq 1 || ! -f "$LENSFUN_DB_DEST/mil-sony.xml" || ! -f "$LENSFUN_DB_DEST/cc-by-sa-3.0.txt" ]]; then
  log "Syncing offline LensfunDB XML files & CC-BY-SA-3.0 license..."
  mkdir -p "$LENSFUN_DB_DEST"
  rm -f "$LENSFUN_DB_DEST"/*.xml "$LENSFUN_DB_DEST/timestamp.txt"
  cp "$INSTALL_DIR/share/lensfun/version_1/"*.xml "$LENSFUN_DB_DEST/"
  if [[ -f "$INSTALL_DIR/share/lensfun/version_1/timestamp.txt" ]]; then
    cp "$INSTALL_DIR/share/lensfun/version_1/timestamp.txt" "$LENSFUN_DB_DEST/"
  fi
  if [[ -f "$LENSFUN_SRC/docs/cc-by-sa-3.0.txt" ]]; then
    cp "$LENSFUN_SRC/docs/cc-by-sa-3.0.txt" "$LENSFUN_DB_DEST/cc-by-sa-3.0.txt"
  fi
fi

mkdir -p "$NOISE_PROFILES_DIR"
touch "$NOISE_PROFILES_DIR/.gitkeep"

# ------------------------------------------------------------------------------
# Step 5/6: libultrahdr 2.0.2 (Apache-2.0, JPEG-only, ISO + XMP, HEIF=OFF)
# ------------------------------------------------------------------------------
UHDR_VER="2.0.2"
UHDR_TAR="$CACHE_DIR/libultrahdr-${UHDR_VER}.tar.gz"
UHDR_SRC="$SRC_DIR/libultrahdr-${UHDR_VER}"
UHDR_BLD="$BUILD_DIR/libultrahdr"
UHDR_XCF="$XCF_DIR/LibUltraHDR.xcframework"

if [[ "$FORCE" -eq 1 || ! -f "$INSTALL_DIR/lib/libuhdr.a" || ! -f "$UHDR_XCF/macos-arm64/libuhdr.a" ]]; then
  log "Step 5/6: Building libultrahdr ${UHDR_VER} (Apache-2.0, HEIF=OFF, ISO=ON, XMP=ON)..."
  fetch_tarball "https://github.com/google/libultrahdr/archive/refs/tags/v${UHDR_VER}.tar.gz" "$UHDR_TAR"
  rm -rf "$UHDR_SRC" "$UHDR_BLD" "$UHDR_XCF"
  tar -xzf "$UHDR_TAR" -C "$SRC_DIR"

  cmake -S "$UHDR_SRC" -B "$UHDR_BLD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DUHDR_ENABLE_HEIF=OFF \
    -DUHDR_WRITE_ISO=ON \
    -DUHDR_WRITE_XMP=ON \
    -DUHDR_BUILD_EXAMPLES=ON \
    -DUHDR_BUILD_TESTS=OFF \
    -DUHDR_BUILD_DEPS=OFF \
    -DUHDR_ENABLE_INSTALL=ON \
    -DJPEG_INCLUDE_DIR="/opt/homebrew/opt/jpeg-turbo/include" \
    -DJPEG_LIBRARY="/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.a"

  cmake --build "$UHDR_BLD" -j"$JOBS"
  cmake --install "$UHDR_BLD"

  if [[ -x "$UHDR_BLD/ultrahdr_app" && ! -x "$INSTALL_DIR/bin/ultrahdr_app" ]]; then
    cp "$UHDR_BLD/ultrahdr_app" "$INSTALL_DIR/bin/ultrahdr_app"
  fi

  mkdir -p "$UHDR_XCF/macos-arm64/Headers"
  cp "$INSTALL_DIR/lib/libuhdr.a" "$UHDR_XCF/macos-arm64/libuhdr.a"
  cp "$INSTALL_DIR/include/ultrahdr_api.h" "$UHDR_XCF/macos-arm64/Headers/ultrahdr_api.h"
  write_xcframework_plist "$UHDR_XCF/Info.plist" "libuhdr.a"
else
  log "Step 5/6: libultrahdr already built (pass --force to rebuild)."
fi

# ------------------------------------------------------------------------------
# Step 6/6: libavif 1.4.2 (BSD-2, SVT-AV1 + libaom + dav1d + libyuv LOCAL)
# ------------------------------------------------------------------------------
AVIF_VER="1.4.2"
AVIF_TAR="$CACHE_DIR/libavif-${AVIF_VER}.tar.gz"
AVIF_SRC="$SRC_DIR/libavif-${AVIF_VER}"
AVIF_BLD="$BUILD_DIR/libavif"
AVIF_XCF="$XCF_DIR/LibAVIF.xcframework"

if [[ "$FORCE" -eq 1 || ! -f "$INSTALL_DIR/lib/libavif.a" || ! -f "$AVIF_XCF/macos-arm64/libavif.a" ]]; then
  log "Step 6/6: Building libavif ${AVIF_VER} (BSD-2, SVT-AV1 + libaom + dav1d + libyuv LOCAL)..."
  fetch_tarball "https://github.com/AOMediaCodec/libavif/archive/refs/tags/v${AVIF_VER}.tar.gz" "$AVIF_TAR"
  rm -rf "$AVIF_SRC" "$AVIF_BLD" "$AVIF_XCF"
  tar -xzf "$AVIF_TAR" -C "$SRC_DIR"

  cmake -S "$AVIF_SRC" -B "$AVIF_BLD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DAVIF_CODEC_SVT=SYSTEM \
    -DAVIF_CODEC_AOM=SYSTEM \
    -DAVIF_CODEC_DAV1D=SYSTEM \
    -DAVIF_LIBYUV=LOCAL \
    -DAVIF_LIBSHARPYUV=OFF \
    -DAVIF_ZLIBPNG=SYSTEM \
    -DAVIF_JPEG=SYSTEM \
    -DJPEG_INCLUDE_DIR="/opt/homebrew/opt/jpeg-turbo/include" \
    -DJPEG_LIBRARY="/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.a" \
    -DPNG_PNG_INCLUDE_DIR="/opt/homebrew/opt/libpng/include" \
    -DPNG_LIBRARY="/opt/homebrew/opt/libpng/lib/libpng.dylib" \
    -DAVIF_BUILD_APPS=ON \
    -DAVIF_BUILD_EXAMPLES=OFF \
    -DAVIF_BUILD_TESTS=OFF

  cmake --build "$AVIF_BLD" -j"$JOBS"
  cmake --install "$AVIF_BLD"

  mkdir -p "$AVIF_XCF/macos-arm64/Headers/avif"
  cp "$INSTALL_DIR/lib/libavif.a" "$AVIF_XCF/macos-arm64/libavif.a"
  cp -R "$INSTALL_DIR/include/avif/"* "$AVIF_XCF/macos-arm64/Headers/avif/"
  write_xcframework_plist "$AVIF_XCF/Info.plist" "libavif.a"
else
  log "Step 6/6: libavif already built (pass --force to rebuild)."
fi

# ------------------------------------------------------------------------------
# Post-build verification
# ------------------------------------------------------------------------------
check_symbol() {
  local archive="$1"
  local sym="$2"
  local syms
  syms="$(nm -gU "$archive")"
  if ! grep -q -- "$sym" <<< "$syms"; then
    echo "ERROR: Missing expected symbol '$sym' in $archive" >&2
    exit 1
  fi
}

log "Verifying built artifacts..."
AVIF_VERSION_OUT="$("$INSTALL_DIR/bin/avifenc" --version)"
echo "$AVIF_VERSION_OUT"
grep -q "svt" <<< "$AVIF_VERSION_OUT"
grep -q "aom" <<< "$AVIF_VERSION_OUT"
grep -q "dav1d" <<< "$AVIF_VERSION_OUT"
grep -q "libyuv : available" <<< "$AVIF_VERSION_OUT"

grep -q "LIBRAW_RAWSPECIAL_SRAW_NO_RGB" "$LIBRAW_XCF/macos-arm64/Headers/libraw/libraw_const.h"
grep -q "as_shot_wb_applied" "$LIBRAW_XCF/macos-arm64/Headers/libraw/libraw_types.h"
check_symbol "$LIBRAW_XCF/macos-arm64/libraw_r.a" "ahd_interpolate"
check_symbol "$LIBRAW_XCF/macos-arm64/libraw_r.a" "dcb"
check_symbol "$LIBRAW_XCF/macos-arm64/libraw_r.a" "dht_interpolate"

check_symbol "$RTPROC_XCF/macos-arm64/librtprocess.a" "amaze_demosaic"
check_symbol "$RTPROC_XCF/macos-arm64/librtprocess.a" "lmmse_demosaic"

grep -q "lf_db_load_directory" "$LENSFUN_XCF/macos-arm64/Headers/lensfun/lensfun.h"
check_symbol "$LENSFUN_XCF/macos-arm64/liblensfun.a" "lf_db_load_directory"
test -f "$LENSFUN_DB_DEST/mil-sony.xml"
test -f "$LENSFUN_DB_DEST/cc-by-sa-3.0.txt"
test -f "$NOISE_PROFILES_DIR/.gitkeep"

grep -q "uhdr_enc_set_compressed_image" "$UHDR_XCF/macos-arm64/Headers/ultrahdr_api.h"
grep -q "avifEncoderAddImageGrid" "$AVIF_XCF/macos-arm64/Headers/avif/avif.h"

test -x "$INSTALL_DIR/bin/ultrahdr_app"
log "Checking ultrahdr_app -P support:"
UHDR_APP_OUT="$("$INSTALL_DIR/bin/ultrahdr_app" 2>&1 || true)"
grep -q -- "-P" <<< "$UHDR_APP_OUT"
BREW_UHDR_OUT="$("/opt/homebrew/bin/ultrahdr_app" 2>&1 || true)"
grep -q -- "-P" <<< "$BREW_UHDR_OUT"

log "All native Vendor dependencies and XCFrameworks built and verified successfully!"
